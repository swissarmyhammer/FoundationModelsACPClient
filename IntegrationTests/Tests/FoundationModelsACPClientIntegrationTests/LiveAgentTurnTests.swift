import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPClient
import FoundationModelsRouter
import FoundationModelsRouterTestSupport
import Testing

// The integration test of this library: one turn of `ConnectionModel` and
// `SessionModel` against a real agent with a real model.
//
// The test uses the public API of the library only: it imports the library
// with no `@testable`. The agent is `RoutedACPAgent` of
// FoundationModelsACPAgent, in this process, over an `InMemoryTransport`
// pair. The package boundary selects this test: the root `swift test` does
// not see this target, and `swift test --package-path IntegrationTests` runs
// it.

/// The time limit of the test, in minutes. It includes the download of the
/// model on the first run, and the load of the model.
private let liveTurnTimeLimitMinutes = 20

/// One turn against a real agent: connect, initialize, open a session, send
/// one prompt, and disconnect.
struct LiveAgentTurnTests {
    /// The dotfolder name of the agent. The configuration stack and the
    /// transcripts of the agent use this name.
    private static let agentName = "acp-client-integration"

    /// The model of the `standard` slot, which answers the prompt. It is the
    /// smallest generation model that the integration suites of
    /// FoundationModelsACPAgent load. See the manifest of this package.
    private static let standardModel = "mlx-community/Qwen3-4B-4bit"

    /// The model of the `flash` slot. The router refuses a profile that names
    /// one model for the `standard` slot and the `flash` slot, so this slot
    /// names a smaller model. The `agents-demo` example of
    /// FoundationModelsAgents uses the same pair.
    private static let flashModel = "mlx-community/Qwen3-1.7B-4bit"

    /// The user-layer `config.yaml` of the agent.
    ///
    /// The profile names two small models. The skills marketplace list is
    /// empty and the code context is off, so the turn does not use the
    /// network and does not index the workspace.
    private static let userConfigYAML = """
        tools:
          codeContext: false
          skills:
            marketplaces: []
        profile:
          standard: ["\(standardModel)"]
          flash: ["\(flashModel)"]
        """

    /// The text of the one prompt.
    private static let promptText = "Say hello in one short sentence."

    /// How long the test waits for the session model to show the answer
    /// after the prompt response. The session model applies each update on
    /// its stream task, so the transcript can show the answer after the
    /// prompt returns.
    private static let answerDeadline: Duration = .seconds(30)

    /// The interval between two reads of the transcript while the test waits
    /// for the answer.
    private static let answerPollInterval: Duration = .milliseconds(50)

    /// The client identity that the test gives in `initialize`.
    private static let clientInfo = Implementation(
        name: "acp-client-integration-test", version: "1.0.0")

    /// `ConnectionModel` connects to a real agent, opens a session, sends one
    /// prompt that the real model answers, and closes the session on
    /// disconnect.
    @Test(.timeLimit(.minutes(liveTurnTimeLimitMinutes)))
    @MainActor
    func aConnectionModelRunsOneTurnAgainstARealAgent() async throws {
        let root = try Self.makeTemporaryDirectory()
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let agent = try await Self.makeAgent(under: root, workspace: workspace)
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await AgentSideConnection(stream: agentEnd, logger: .disabled) { connection in
            agent.bind(connection: connection)
            return agent
        }

        let model = ConnectionModel(coalescingCadence: .zero)
        _ = await model.connect(over: clientEnd)
        _ = try await model.initialize(
            InitializeRequest(
                info: Self.clientInfo,
                protocolVersion: ACPClient.supportedProtocolVersion,
                capabilities: ACPClient.advertisedCapabilities))
        #expect(model.state == .connected)

        let session = try await model.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
        #expect(model.openSessions.count == 1)

        _ = try await session.prompt([.text(TextContent(text: Self.promptText))])
        let userMessage = try #require(Self.firstUserMessage(in: session))
        #expect(userMessage.sendState == .sent)
        let answer = try await Self.waitForAgentText(in: session)
        #expect(!answer.isEmpty, "the transcript holds no agent message with text")

        await model.disconnect()
        #expect(model.openSessions.isEmpty)
        #expect(session.isClosed)
        #expect(model.state == .disconnected)

        _ = await agentConnection.closed
        await agent.waitForConnectionTeardown()
        try FileManager.default.removeItem(at: root)
    }

    /// Makes a new temporary directory, with each symbolic link of its path
    /// resolved.
    ///
    /// - Returns: The directory.
    /// - Throws: The error of the directory creation.
    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(agentName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }

    /// Makes the real agent: writes ``userConfigYAML`` into a user layer under
    /// `root`, loads the configuration, and resolves the profile through a
    /// router that loads the real model and decodes greedy.
    ///
    /// - Parameters:
    ///   - root: The temporary directory of the test.
    ///   - workspace: The working directory of the session.
    /// - Returns: The agent, with its models loaded.
    /// - Throws: The error of the file write, of the configuration load, or of
    ///   the profile resolution.
    private static func makeAgent(under root: URL, workspace: URL) async throws -> RoutedACPAgent {
        // Under `swift test`, MLX does not find its shader library beside the
        // test binary. This bootstrap links it there, before the first model
        // load.
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        let userDirectory = root.appendingPathComponent("user", isDirectory: true)
        let recordingsDirectory = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        try userConfigYAML.write(
            to: userDirectory.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
        let name = try DotfolderName(agentName)
        let configuration = try ConfigurationLoader(
            name: name,
            workingDirectory: workspace,
            userDirectory: userDirectory,
            environment: [:]
        ).load().configuration
        let router = Router(
            recordingsDir: recordingsDirectory,
            loader: LiveModelLoader(),
            samplingMode: .greedy)
        return try await RoutedACPAgent(
            name: name,
            router: router,
            configuration: configuration,
            userDirectory: userDirectory,
            environment: [:])
    }

    /// Gives the first user message of the transcript of `session`.
    ///
    /// - Parameter session: The session model.
    /// - Returns: The user message, or `nil` when the transcript holds none.
    @MainActor
    private static func firstUserMessage(in session: SessionModel) -> UserMessageEntry? {
        session.transcript.lazy.compactMap { entry in
            guard case .userMessage(let message) = entry else { return nil }
            return message
        }.first
    }

    /// Waits until the transcript of `session` holds agent message text, or
    /// until ``answerDeadline``.
    ///
    /// - Parameter session: The session model.
    /// - Returns: The text of each agent message, joined. The text is empty
    ///   when no agent message text came before the deadline.
    /// - Throws: `CancellationError` when the test task is cancelled.
    @MainActor
    private static func waitForAgentText(in session: SessionModel) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: answerDeadline)
        var text = agentText(in: session)
        while text.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: answerPollInterval)
            text = agentText(in: session)
        }
        return text
    }

    /// Gives the text of each agent message of the transcript of `session`,
    /// joined in transcript order.
    ///
    /// - Parameter session: The session model.
    /// - Returns: The joined text.
    @MainActor
    private static func agentText(in session: SessionModel) -> String {
        session.transcript
            .flatMap { entry -> [ContentBlock] in
                guard case .agentMessage(let message) = entry else { return [] }
                return message.content
            }
            .compactMap { block -> String? in
                guard case .text(let content) = block else { return nil }
                return content.text
            }
            .joined()
    }
}
