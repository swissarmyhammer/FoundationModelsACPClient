import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// M6: the in-process deployment. `InMemoryTransport.pair()` wires this
// client to an agent in the same process, over the real ACP wire.

/// The session id the stub agent gives out.
private let stubSessionID = SessionId(rawValue: "stub-session")

/// The message id the stub agent stamps on its one reply chunk.
private let stubMessageID = MessageId(rawValue: "stub-agent-msg-1")

/// The reply text the stub agent streams for every prompt.
private let stubReplyText = "Hello from the stub agent."

/// A `FoundationModelsACPAgent`-shaped stub: an in-process `Agent` that
/// serves the v2 session baseline over a real `AgentSideConnection`.
///
/// `prompt(_:)` streams one agent-message chunk and one idle `state_update`
/// with `end_turn`, then acknowledges. The updates go out before the
/// acknowledgement; the client tolerates both orders.
private final class InProcessStubAgent: Agent {
    /// The connection the factory handed this agent, for reverse calls.
    let connection: AgentSideConnection

    /// Creates the stub bound to its own connection.
    ///
    /// - Parameter connection: The connection the factory handed this agent.
    init(connection: AgentSideConnection) {
        self.connection = connection
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "in-process-stub-agent", version: "1.0.0"),
            protocolVersion: params.protocolVersion
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: stubSessionID)
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: [])
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        throw RequestError.methodNotFound("session/resume")
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        throw RequestError.methodNotFound("session/close")
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        let chunk = SessionUpdate.agentMessageChunk(
            ContentChunk(content: .text(TextContent(text: stubReplyText)), messageId: stubMessageID)
        )
        try await connection.sessionUpdate(
            UpdateSessionNotification(sessionId: params.sessionId, update: chunk)
        )
        try await connection.sessionUpdate(
            UpdateSessionNotification(
                sessionId: params.sessionId,
                update: .stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn)))
            )
        )
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

/// Full session over `InMemoryTransport.pair()`: initialize, `session/new`,
/// prompt, updates, stop. The observable state lands the streamed reply,
/// and the connection state follows the transport.
@MainActor
@Test func fullSessionOverInMemoryPair() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
        InProcessStubAgent(connection: connection)
    }
    let client = SwiftUIACPClient()
    #expect(client.connectionState == .disconnected)

    let connection = await client.connect(over: clientEnd)
    #expect(client.connectionState == .connected)

    let initialized = try await connection.initialize(makeInitializeRequest())
    #expect(initialized.protocolVersion == ACPClient.supportedProtocolVersion)

    let cwd = try #require(AbsolutePath(rawValue: "/"))
    let session = try await connection.newSession(NewSessionRequest(cwd: cwd))
    #expect(session.sessionId == stubSessionID)

    let replyLanded = try await promptTurnLandsReply(
        over: connection,
        client: client,
        sessionId: session.sessionId,
        messageID: stubMessageID,
        expectedText: stubReplyText
    )
    #expect(replyLanded)
    let state = client.session(for: session.sessionId)
    #expect(state.lastStopReason == .endTurn)
    #expect(state.turnState == .idle)

    await connection.close()
    #expect(await eventually { client.connectionState == .disconnected })
    _ = agentConnection
}

/// Closing the connection from the host side surfaces as `.disconnected`
/// observable state, and never as a hang.
@MainActor
@Test func hostCloseSurfacesDisconnectedState() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
        InProcessStubAgent(connection: connection)
    }
    let client = SwiftUIACPClient()
    let connection = await client.connect(over: clientEnd)
    #expect(client.connectionState == .connected)

    await connection.close()
    #expect(await eventually { client.connectionState == .disconnected })
    _ = agentConnection
}
