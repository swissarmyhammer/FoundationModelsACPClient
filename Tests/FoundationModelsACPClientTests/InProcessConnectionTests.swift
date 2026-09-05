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

    let cwd = AbsolutePath(rawValue: "/")
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

// The wrapping-`Client` seam. `connect(over:logger:client:)` lets a host
// put a `Client` of its own in front of this container, and the tests
// below hold that seam to its documented contract: the connection serves
// the wrapper, the closure runs one time with the container, a wrapper
// that forwards keeps the container's state current, and the connection's
// life is unchanged.

/// The reply text the seam tests script.
private let seamReplyText = "Hello from the scripted stub agent."

/// The message id the seam tests stamp on the scripted reply chunk.
private let seamMessageID = MessageId(rawValue: "seam-agent-msg-1")

/// The update script the seam tests drive: one agent-message chunk, then
/// the idle state that ends the turn.
private let seamScript: [SessionUpdate] = [
    agentChunk(text: seamReplyText, message: seamMessageID.rawValue),
    idleState(stopReason: .endTurn),
]

/// How a ``RecordingClientWrapper`` answers a permission request.
private enum WrapperPermissionPolicy {
    /// Forwards the request to the container, so a person answers it.
    case forwardToContainer

    /// Answers `cancelled` inside the wrapper, because no person is there
    /// to answer. This is the headless-host policy the CLI needs.
    case declineInTheWrapper
}

/// A `Client` that stands in front of a ``SwiftUIACPClient`` container.
///
/// This is the shape ``SwiftUIACPClient/connect(over:logger:client:)``
/// documents: the wrapper forwards `sessionUpdate(_:)` and
/// `elicitationComplete(_:)` to the container, so the observable state
/// stays current, and it may answer a request itself. The counters let a
/// test prove which `Client` the agent reached.
@MainActor
private final class RecordingClientWrapper: Client {
    /// The container this wrapper stands in front of.
    private let container: SwiftUIACPClient

    /// How this wrapper answers a permission request.
    private let permissionPolicy: WrapperPermissionPolicy

    /// The number of times a connect closure noted that it built this
    /// wrapper.
    private(set) var factoryCallCount = 0

    /// The number of session updates this wrapper forwarded.
    private(set) var forwardedUpdateCount = 0

    /// The number of permission requests this wrapper answered itself.
    private(set) var answeredPermissionCount = 0

    /// Creates the wrapper.
    ///
    /// - Parameters:
    ///   - container: The container this wrapper stands in front of.
    ///   - permissionPolicy: How the wrapper answers a permission request.
    init(
        container: SwiftUIACPClient,
        permissionPolicy: WrapperPermissionPolicy = .forwardToContainer
    ) {
        self.container = container
        self.permissionPolicy = permissionPolicy
    }

    /// Records one run of the connect closure that built this wrapper.
    func noteFactoryCall() {
        factoryCallCount += 1
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        forwardedUpdateCount += 1
        await container.sessionUpdate(notification)
    }

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        switch permissionPolicy {
        case .forwardToContainer:
            return try await container.requestPermission(params)
        case .declineInTheWrapper:
            answeredPermissionCount += 1
            return RequestPermissionResponse(outcome: .cancelled)
        }
    }

    func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse {
        try await container.createElicitation(params)
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        await container.elicitationComplete(notification)
    }
}

/// Drives one scripted turn over a fresh in-process pair, and reports
/// whether the container landed the scripted reply.
///
/// The two `connect` overloads differ only in the call `connect` makes, so
/// each test that names an overload reads as one line.
///
/// - Parameters:
///   - container: The container whose session state must land the reply.
///   - connect: Attaches the container to the client end of the pair.
/// - Returns: `true` when the scripted reply landed in the container's
///   session state.
@MainActor
private func scriptedTurnLandsReply(
    into container: SwiftUIACPClient,
    connectingWith connect: (any ACPTransport) async -> ClientSideConnection
) async throws -> Bool {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConnection = await AgentSideConnection(stream: agentEnd) { agentSide in
        ScriptedStubAgent(connection: agentSide, session: testSession, script: seamScript)
    }
    let connection = await connect(clientEnd)
    let landed = try await promptTurnLandsReply(
        over: connection,
        client: container,
        sessionId: testSession,
        messageID: seamMessageID,
        expectedText: seamReplyText
    )
    await connection.close()
    withExtendedLifetime(agentConnection) {}
    return landed
}

/// The wrapping overload serves the `Client` the closure returns, and it
/// runs that closure one time with the container. A wrapper that forwards
/// `sessionUpdate(_:)` sees every update and keeps the container's session
/// state current.
@MainActor @Test(.timeLimit(.minutes(1)))
func aWrappingClientForwardsEveryUpdateIntoTheContainer() async throws {
    let container = SwiftUIACPClient()
    let wrapper = RecordingClientWrapper(container: container)

    let replyLanded = try await scriptedTurnLandsReply(into: container) { transport in
        await container.connect(over: transport) { received in
            #expect(received === container)
            wrapper.noteFactoryCall()
            return wrapper
        }
    }

    #expect(replyLanded)
    #expect(wrapper.factoryCallCount == 1)
    #expect(wrapper.forwardedUpdateCount == seamScript.count)
}

/// A wrapper that answers `requestPermission` itself is the `Client` the
/// agent reaches, so the container never shows the prompt.
@MainActor @Test(.timeLimit(.minutes(1)))
func aWrapperThatAnswersPermissionKeepsTheContainerPromptEmpty() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConnection = await AgentSideConnection(stream: agentEnd) { agentSide in
        PermissionStubAgent(connection: agentSide)
    }
    let container = SwiftUIACPClient()
    let wrapper = RecordingClientWrapper(
        container: container,
        permissionPolicy: .declineInTheWrapper
    )
    let connection = await container.connect(over: clientEnd) { _ in wrapper }

    _ = try await connection.prompt(
        PromptRequest(prompt: [textBlock("go")], sessionId: testSession)
    )

    #expect(wrapper.answeredPermissionCount == 1)
    #expect(container.session(for: testSession).pendingPermissionRequests.isEmpty)

    await connection.close()
    withExtendedLifetime(agentConnection) {}
}

/// The disconnect path is the same on the wrapping overload: the stream
/// ends, and `connectionState` becomes `.disconnected`.
@MainActor @Test(.timeLimit(.minutes(1)))
func hostCloseOnTheWrappingOverloadSurfacesDisconnectedState() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
        InProcessStubAgent(connection: connection)
    }
    let container = SwiftUIACPClient()
    let wrapper = RecordingClientWrapper(container: container)
    let connection = await container.connect(over: clientEnd) { _ in wrapper }
    #expect(container.connectionState == .connected)

    await connection.close()
    #expect(await eventually { container.connectionState == .disconnected })
    withExtendedLifetime(agentConnection) {}
}

/// The two-argument overload keeps its behaviour: it serves the container
/// itself, with no wrapper between the agent and the observable state.
@MainActor @Test(.timeLimit(.minutes(1)))
func theTwoArgumentConnectServesTheContainerItself() async throws {
    let container = SwiftUIACPClient()

    let replyLanded = try await scriptedTurnLandsReply(into: container) { transport in
        await container.connect(over: transport)
    }

    #expect(replyLanded)
}
