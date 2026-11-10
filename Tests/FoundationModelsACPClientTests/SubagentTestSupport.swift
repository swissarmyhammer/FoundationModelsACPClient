import FoundationModelsACP
import Synchronization
import Testing

@testable import FoundationModelsACPClient

/// Finds a child session in the tree under a root session, at any level.
///
/// - Parameters:
///   - sessionId: The id of the child.
///   - root: The session whose tree to search.
/// - Returns: The model, or `nil` when no model under the root has that id.
@MainActor
func childModel(_ sessionId: SessionId, under root: SessionModel) -> SessionModel? {
    for child in root.children {
        if child.id == sessionId { return child }
        if let found = childModel(sessionId, under: child) { return found }
    }
    return nil
}

/// Waits until the model made a child session, and gives the child.
///
/// - Parameters:
///   - sessionId: The id of the child.
///   - root: The session whose tree to search. Its close is the failure event.
/// - Returns: The model of the child.
/// - Throws: ``WaitEndedOnFailure`` when the root closed first.
@MainActor
func waitForChild(_ sessionId: SessionId, under root: SessionModel) async throws -> SessionModel {
    try await waitForObservation { childModel(sessionId, under: root) != nil } orFailWhen: { root.isClosed }
    return try #require(childModel(sessionId, under: root))
}

/// A stub agent that answers `initialize` with the session baseline and
/// refuses each other method that the test does not model with
/// `methodNotFound`, as an agent that does not implement it does. A stub
/// conforms to it and implements only what its test needs.
protocol BaselineStubAgent: Agent {}

extension BaselineStubAgent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "baseline-stub-agent", version: "1.0.0"),
            protocolVersion: params.protocolVersion,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.listSessions)
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.closeSession)
    }

    func loginAuth(_ params: LoginAuthRequest) async throws -> LoginAuthResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.login)
    }

    func logoutAuth(_ params: LogoutAuthRequest) async throws -> LogoutAuthResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.logout)
    }

    func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.deleteSession)
    }

    func setSessionConfigOption(_ params: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.setConfigOption)
    }
}

/// A connected model, its stub agent and its root session.
@MainActor
struct ConnectedStub<Stub: Agent & Sendable> {
    /// The model under test.
    let model: ConnectionModel

    /// The agent-side connection. The test holds it so that the agent end of
    /// the pair outlives the test body.
    let agentConnection: AgentSideConnection

    /// The stub agent.
    let agent: Stub

    /// The open root session.
    let root: SessionModel

    /// Connects a model to the stub that `makeStub` builds, initializes it,
    /// and opens the root session. The connect, the initialize and the open
    /// are network work, so a factory does them and no initializer does.
    ///
    /// - Parameters:
    ///   - bufferLimits: The limits on the events that the connection keeps
    ///     for a session with no model.
    ///   - extensions: The extensions that the model adds before the
    ///     connect, in order.
    ///   - makeStub: Builds the stub from its connection.
    /// - Returns: The connected stub.
    /// - Throws: The error of `initialize` or of `session/new`.
    static func make(
        bufferLimits: SessionUpdateBufferLimits = .default,
        extensions: [any ClientModelExtension] = [],
        makeStub: @escaping @Sendable (AgentSideConnection) -> Stub
    ) async throws -> Self {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let built = Mutex<Stub?>(nil)
        let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            let stub = makeStub(connection)
            built.withLock { $0 = stub }
            return stub
        }
        let model = ConnectionModel(coalescingCadence: .zero)
        for clientExtension in extensions {
            model.addExtension(clientExtension)
        }
        _ = await model.connect(over: clientEnd, bufferLimits: bufferLimits)
        _ = try await model.initialize(makeInitializeRequest())
        let root = try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: "/")))
        let agent = try #require(built.withLock { $0 })
        return Self(model: model, agentConnection: agentConnection, agent: agent, root: root)
    }
}

/// A stub agent that sends one session update to a session of the test's
/// choice.
protocol UpdateSendingStubAgent: Agent {
    /// Sends one update for a session.
    ///
    /// - Parameters:
    ///   - update: The update to send.
    ///   - sessionId: The session that the update names.
    func send(_ update: SessionUpdate, to sessionId: SessionId) async throws
}

extension ConnectedStub where Stub: UpdateSendingStubAgent {
    /// Sends a snapshot of a child in the stream of its parent, and waits
    /// until the model made the child.
    ///
    /// - Parameters:
    ///   - update: The `subagent_update` update.
    ///   - sessionId: The id of the child.
    ///   - parent: The parent session.
    /// - Returns: The model of the child.
    /// - Throws: ``WaitEndedOnFailure`` when the root session closed first.
    @discardableResult
    func announce(_ update: SessionUpdate, child sessionId: SessionId, in parent: SessionId = testSession) async throws
        -> SessionModel
    {
        try await agent.send(update, to: parent)
        return try await waitForChild(sessionId, under: root)
    }
}
