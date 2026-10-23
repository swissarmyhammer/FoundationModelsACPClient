import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

/// Tests of ``InProcessAgent``: the helper connects a `ConnectionModel` to an
/// ACP agent that runs in the process of the host.
///
/// The agent is a ``ScriptedStubAgent``. Each test reads the state of the
/// returned `ConnectionModel` and of its `SessionModel` directly, because the
/// helper keeps no state of its own. No wait reads a clock or polls.
@MainActor
@Suite
struct InProcessAgentTests {
    /// The text of the prompt of the round trip.
    static let promptText = "hello"

    /// The text of the reply of the agent.
    static let replyText = "hello from the agent"

    /// The message id of the reply of the agent.
    static let replyMessage = MessageId(rawValue: "in-process-reply-1")

    /// The working directory of the new session.
    static let workingDirectory = AbsolutePath(rawValue: "/tmp/in-process-agent")

    /// The model that the helper returned, and the agent side of its
    /// connection.
    struct Connection {
        /// The model that the helper returned.
        let model: ConnectionModel

        /// The agent side of the connection, which the factory of the helper
        /// got.
        let agentConnection: AgentSideConnection
    }

    /// Connects a model to a new stub agent through the helper.
    ///
    /// - Parameter script: The updates that the agent sends during a prompt,
    ///   before the prompt answer.
    /// - Returns: The model and the agent side of the connection. Disconnect
    ///   the model in a `defer` right after the call, so the close runs also
    ///   when the test body throws.
    /// - Throws: An issue when the factory did not run. Before it throws, the
    ///   call disconnects the model.
    static func connect(script: [SessionUpdate] = []) async throws -> Connection {
        let agentConnections = ThreadSafeBuffer<AgentSideConnection>()
        let model = await InProcessAgent.makeConnection { agentConnection in
            agentConnections.append(agentConnection)
            return ScriptedStubAgent(connection: agentConnection, session: testSession, script: script)
        }
        do {
            return Connection(model: model, agentConnection: try #require(agentConnections.elements.last))
        } catch {
            await model.disconnect()
            throw error
        }
    }

    /// Gives the text of the agent message with the reply id.
    ///
    /// - Parameter session: The session model.
    /// - Returns: The joined text of the message, or `nil` when the transcript
    ///   has no such message.
    static func agentReply(in session: SessionModel) -> String? {
        session.transcript
            .compactMap(\.agentMessage)
            .first { $0.messageId == replyMessage }?
            .content.joinedText
    }

    @Test func theReturnedModelIsConnected() async throws {
        let connection = try await Self.connect()
        defer { await connection.model.disconnect() }

        #expect(connection.model.state == .connected)
    }

    @Test func aPromptRoundTripPutsTheReplyOfTheAgentInTheTranscript() async throws {
        let connection = try await Self.connect(script: [
            agentChunk(text: Self.replyText, message: Self.replyMessage.rawValue),
            idleState(stopReason: .endTurn),
        ])
        defer { await connection.model.disconnect() }

        _ = try await connection.model.initialize(makeInitializeRequest())
        let session = try await connection.model.newSession(NewSessionRequest(cwd: Self.workingDirectory))
        _ = try await session.prompt([textBlock(Self.promptText)])

        try await waitUntil { Self.agentReply(in: session) == Self.replyText } orFailWhen: { session.isClosed }
        #expect(Self.agentReply(in: session) == Self.replyText)
    }

    @Test func theStateOfTheModelBecomesDisconnectedAfterTheAgentCloses() async throws {
        let connection = try await Self.connect()
        defer { await connection.model.disconnect() }

        await connection.agentConnection.close()

        // A failed state is the close with the wrong reason, so it ends the
        // wait as a failure.
        try await waitUntil { connection.model.state == .disconnected } orFailWhen: {
            if case .failed = connection.model.state { true } else { false }
        }
        #expect(connection.model.state == .disconnected)
    }

    /// A disconnect of the model stops the read of the client end of the pair.
    /// `InMemoryTransport.pair()` then ends the input of the agent side, so the
    /// agent side closes because of the end of its input.
    @Test func aDisconnectOfTheModelClosesTheAgentSide() async throws {
        let connection = try await Self.connect()
        defer { await connection.model.disconnect() }

        await connection.model.disconnect()

        // Without the end of the input of the agent side, this read never
        // ends.
        #expect(await connection.agentConnection.closed.isEndOfInput)
        #expect(connection.model.state == .disconnected)
    }
}
