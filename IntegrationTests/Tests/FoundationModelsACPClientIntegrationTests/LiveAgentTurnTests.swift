import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Testing

// The integration test of this library: one turn of `ConnectionModel` and
// `SessionModel` against a real agent with a real model.
//
// The test uses the public API of the library only: it imports the library
// with no `@testable`. The agent is `RoutedACPAgent` of
// FoundationModelsACPAgent, with greedy decoding, in the `live-agent-server`
// process, over its stdio. `LiveAgentServerBuild` builds that executable. The
// package boundary selects this test: the root `swift test` does not see this
// target, and `swift test --package-path IntegrationTests` runs it.

/// The time limit of the test, in minutes. It includes the build of the
/// agent server, the download of the model on the first run, and the load of
/// the model.
private let liveTurnTimeLimitMinutes = 30

/// One turn against a real agent: connect, initialize, open a session, send
/// one prompt, and disconnect.
struct LiveAgentTurnTests {
    /// The prefix of the name of the temporary directory of the test.
    private static let temporaryDirectoryPrefix = "acp-client-integration"

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
        let agentProcess = try await Self.startAgent(under: root, workspace: workspace)

        let model = ConnectionModel(coalescingCadence: .zero)
        _ = await model.connect(over: agentProcess.transport)
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

        // The disconnect ends the stdio transport, and the end of the
        // transport ends and reaps the agent process.
        let agentExit = try await agentProcess.waitForExit()
        #expect(agentExit != .notCollected, "the teardown did not reap the agent process")
        try FileManager.default.removeItem(at: root)
    }

    /// Makes a new temporary directory, with each symbolic link of its path
    /// resolved.
    ///
    /// - Returns: The directory.
    /// - Throws: The error of the directory creation.
    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryDirectoryPrefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }

    /// Builds the agent server, and starts it as an external agent over
    /// stdio.
    ///
    /// The server writes its user layer and its recordings under `root`, and
    /// loads its models before it reads the first frame.
    ///
    /// - Parameters:
    ///   - root: The temporary directory of the test. It also receives the
    ///     log of each `swift build`.
    ///   - workspace: The working directory of the configuration load of the
    ///     agent.
    /// - Returns: The agent process. Its transport carries the connection.
    /// - Throws: The error of the build or of the start of the process.
    private static func startAgent(under root: URL, workspace: URL) async throws -> AgentProcess {
        let executable = try await LiveAgentServerBuild(logDirectory: root).makeExecutable()
        return try AgentProcess(command: executable, arguments: [root.path, workspace.path])
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
