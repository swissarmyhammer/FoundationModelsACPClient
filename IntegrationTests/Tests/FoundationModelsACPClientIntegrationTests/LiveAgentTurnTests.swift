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

/// One turn against a real agent: connect, initialize, open a session, send
/// one prompt, wait for the end of its work, and disconnect.
///
/// The prompt is mail: the agent answers `session/prompt` at once with the
/// message id of the inserted user message, and the work of the model comes
/// after the answer. The test waits as the headless CLI does: for the first
/// `idle` after the echo of its own message id. The wait is on the update tap
/// of the session model, so it ends on an event and has no time limit.
struct LiveAgentTurnTests {
    /// The prefix of the name of the temporary directory of the test.
    private static let temporaryDirectoryPrefix = "acp-client-integration"

    /// The text of the one prompt.
    private static let promptText = "Say hello in one short sentence."

    /// The client identity that the test gives in `initialize`.
    private static let clientInfo = Implementation(
        name: "acp-client-integration-test", version: "1.0.0")

    /// `ConnectionModel` connects to a real agent, opens a session, sends one
    /// prompt that the real model answers, and closes the session on
    /// disconnect.
    @Test
    @MainActor
    func aConnectionModelRunsOneTurnAgainstARealAgent() async throws {
        let root = try Self.makeTemporaryDirectory()
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let agentProcess = try await Self.startAgent(under: root, workspace: workspace)
        // This stops the agent process also when the body throws first. After
        // the reap at the end of the body, it does nothing.
        defer { agentProcess.shutdown() }

        let model = ConnectionModel(coalescingCadence: .zero)
        _ = await model.connect(over: agentProcess.transport)
        // The disconnect of the body is the behavior under test. This one
        // closes the connection also when the body throws first.
        defer { await model.disconnect() }
        _ = try await model.initialize(
            InitializeRequest(
                info: Self.clientInfo,
                protocolVersion: ACPClient.supportedProtocolVersion,
                capabilities: ACPClient.advertisedCapabilities))
        #expect(model.state == .connected)

        let session = try await model.newSession(
            NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
        #expect(model.openSessions.count == 1)

        // The tap starts before the prompt, so it holds the echo also when
        // the echo comes before the prompt answer.
        let updates = session.updateTap()
        let response = try await session.prompt([.text(TextContent(text: Self.promptText))])
        let userMessage = try #require(Self.firstUserMessage(in: session))
        #expect(userMessage.sendState == .sent)
        #expect(userMessage.messageId == response.messageId)

        let idle = try #require(
            await Self.firstIdleAfterTheEcho(of: response.messageId, in: updates),
            "the update tap ended before the idle of the prompt")
        #expect(idle.stopReason == .endTurn)
        #expect(!Self.agentText(in: session).isEmpty, "the transcript holds no agent message with text")

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

    /// Reads the update tap until the first `idle` that comes after the echo
    /// of the user message of the prompt, as the headless CLI does.
    ///
    /// An `idle` before the echo belongs to earlier work, for example the
    /// load of the model, and does not end the wait. The session model folds
    /// each update before its stream task reads the next one, so the
    /// transcript holds the answer when the `idle` comes out of the tap.
    ///
    /// - Parameters:
    ///   - messageId: The message id that the prompt answer gave.
    ///   - updates: The update tap of the session model, made before the
    ///     prompt.
    /// - Returns: The idle state, or `nil` when the tap ended first.
    @MainActor
    private static func firstIdleAfterTheEcho(
        of messageId: MessageId,
        in updates: AsyncStream<SessionUpdate>
    ) async -> IdleStateUpdate? {
        var sawEcho = false
        for await update in updates {
            switch update {
            case .userMessage(let message) where message.messageId == messageId:
                sawEcho = true
            case .userMessageChunk(let chunk) where chunk.messageId == messageId:
                sawEcho = true
            case .stateUpdate(.idle(let idle)) where sawEcho:
                return idle
            default:
                break
            }
        }
        return nil
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
