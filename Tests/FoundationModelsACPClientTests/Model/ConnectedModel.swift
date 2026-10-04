import FoundationModelsACP

@testable import FoundationModelsACPClient

/// A model that is connected over an in-memory pair to a scripted stub agent.
///
/// `InMemoryTransport.pair()` gives the real ACP wire, with a
/// ``ScriptedStubAgent`` on the agent end. The stub records each request that
/// it gets, so a test can prove that a request did or did not go out. The
/// initialize tests and the session tests of the connection model share it.
@MainActor
struct ConnectedModel {
    /// The model under test.
    let model: ConnectionModel

    /// The agent-side connection. The test holds it so the agent end of the
    /// pair outlives the test body.
    let agentConnection: AgentSideConnection

    /// The agent end of the pair. A close of it ends the input of the client.
    let agentEnd: InMemoryTransport

    /// The stubs that the agent-side factory built. The factory runs one
    /// time, so the list holds one element.
    private let builtAgents: ThreadSafeBuffer<ScriptedStubAgent>

    /// The ACP method of each request that the agent got, in arrival order.
    var receivedMethods: [String] {
        (builtAgents.elements.last?.receivedMeta ?? []).map(\.method)
    }

    /// Gives the `_meta` that the agent got for one method.
    ///
    /// - Parameter method: The ACP method.
    /// - Returns: The `_meta` of each message of that method, in arrival
    ///   order.
    func receivedMeta(of method: String) -> [JSONValue?] {
        builtAgents.elements.last?.receivedMeta(of: method) ?? []
    }

    /// Each `session/list` request that the agent got, in arrival order.
    var listRequests: [ListSessionsRequest] {
        builtAgents.elements.last?.listRequests ?? []
    }

    /// Each `session/delete` request that the agent got, in arrival order.
    var deleteRequests: [DeleteSessionRequest] {
        builtAgents.elements.last?.deleteRequests ?? []
    }

    /// Connects a model to the stub agent that `makeAgent` builds.
    ///
    /// - Parameters:
    ///   - model: The model to connect.
    ///   - bufferLimits: The limits on the updates that the connection keeps
    ///     for a session with no subscriber.
    ///   - wrap: Builds the `Client` that the connection serves from the
    ///     router of the model. The default serves the router itself.
    ///   - makeAgent: Builds the stub agent from its connection.
    init(
        model: ConnectionModel = ConnectionModel(),
        bufferLimits: SessionUpdateBufferLimits = .default,
        client wrap: @escaping @Sendable @MainActor (any Client) -> any Client = { $0 },
        makeAgent: @escaping @Sendable (AgentSideConnection) -> ScriptedStubAgent
    ) async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let builtAgents = ThreadSafeBuffer<ScriptedStubAgent>()
        self.builtAgents = builtAgents
        self.agentEnd = agentEnd
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            let stub = makeAgent(connection)
            builtAgents.append(stub)
            return stub
        }
        self.model = model
        _ = await model.connect(over: clientEnd, bufferLimits: bufferLimits, client: wrap)
    }

    /// Connects a new model to a new stub agent with no update script.
    ///
    /// - Parameters:
    ///   - capabilities: The capabilities the agent answers `initialize`
    ///     with.
    ///   - authMethods: The auth methods the agent answers `initialize` with,
    ///     or `nil` to leave the member out.
    ///   - loginError: The error the agent refuses each login with, or `nil`
    ///     to accept each login.
    init(
        capabilities: AgentCapabilities = AgentCapabilities(),
        authMethods: [AuthMethod]? = nil,
        loginError: RequestError? = nil
    ) async {
        await self.init { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: [],
                capabilities: capabilities,
                authMethods: authMethods,
                loginError: loginError
            )
        }
    }

    /// Sends `initialize` through the model.
    ///
    /// - Returns: The answer of the agent.
    /// - Throws: Whatever the model threw.
    @discardableResult
    func initialize() async throws -> InitializeResponse {
        try await model.initialize(makeInitializeRequest())
    }
}
