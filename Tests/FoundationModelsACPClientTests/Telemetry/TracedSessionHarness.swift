import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The session harness of the telemetry tests. `ClientRequestSpanTests`,
// `ClientRequestMetricsTests` and `ContentSafetyTests` drive the real
// `ConnectionModel` and `SessionModel` with it, in process, over
// `InMemoryTransport.pair()`, with a `ScriptedStubAgent` on the far end. The
// turn sends its prompt through the `SessionModel` of the session, so each
// span of the prompt opens inside the model.

/// The text of the prompt of each turn of the harness.
///
/// Rule 4 of the OpenTelemetry design: no span, log record or metric holds a
/// prompt. The capture of each turn forbids this text.
let tracedPromptText = "Tell me the secret word of the traced turn."

/// A `Client` in front of the router of a connection model that refuses each
/// permission request with the `cancelled` outcome.
///
/// The harness has no user who could select an option, so it gives the agent
/// the answer that a client with no user gives.
private struct PermissionDecliningClient: Client {
    /// The router that this client stands in front of.
    let router: any Client

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        await router.sessionUpdate(notification)
    }

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        PendingPermissionRequest.cancelledResponse
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        try await router.createElicitation(params)
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        await router.elicitationComplete(notification)
    }
}

/// A ``ConnectionModel`` over one end of an in-memory pair, with a
/// ``ScriptedStubAgent`` on the other end.
@MainActor
struct TracedSessionHarness {
    /// The connection model under test.
    let model: ConnectionModel

    /// The agent-side connection. A test holds it so the far end of the pair
    /// outlives the test body.
    let agentConnection: AgentSideConnection

    /// The text of the prompt of the turn.
    private let prompt: String

    /// The working directory that `session/new` sends.
    private let cwd: String

    /// The stubs the agent-side factory built. The factory runs one time, so
    /// the list holds one element.
    private let builtAgents: ThreadSafeBuffer<ScriptedStubAgent>

    /// Connects a new model to a new stub over a new pair.
    ///
    /// - Parameters:
    ///   - prompt: The text of the prompt of the turn.
    ///   - cwd: The working directory of the session, or `nil` for the
    ///     working directory of the test process.
    ///   - script: The updates the stub sends before it answers the prompt.
    ///   - deferredScript: The updates the stub sends after it answers the
    ///     prompt, one step per gate.
    ///   - permissionRequest: The permission the stub asks for when the
    ///     prompt arrives, or `nil` to ask for none.
    ///   - promptError: The error the stub refuses the prompt with, or `nil`
    ///     to answer the prompt.
    ///   - closeSessionError: The error the stub answers `session/close` with.
    init(
        prompt: String = tracedPromptText,
        cwd: String? = nil,
        script: [SessionUpdate] = [idleState(stopReason: .endTurn)],
        deferredScript: [GatedUpdates] = [],
        permissionRequest: RequestPermissionRequest? = nil,
        promptError: RequestError? = nil,
        closeSessionError: RequestError = .methodNotFound(ClientRequestSpan.Method.closeSession)
    ) async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let builtAgents = ThreadSafeBuffer<ScriptedStubAgent>()
        self.builtAgents = builtAgents
        self.prompt = prompt
        self.cwd = cwd ?? FileManager.default.currentDirectoryPath
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            let stub = ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: script,
                deferredScript: deferredScript,
                permissionRequest: permissionRequest,
                promptError: promptError,
                closeSessionError: closeSessionError,
                // The session baseline holds `session/close`, so the
                // connection model sends the close of each session.
                capabilities: AgentCapabilities(session: SessionCapabilities())
            )
            builtAgents.append(stub)
            return stub
        }
        // A zero cadence, so each chunk is in the model when it arrives.
        model = ConnectionModel(coalescingCadence: .zero, clock: ContinuousClock())
        _ = await model.connect(over: clientEnd) { router in
            PermissionDecliningClient(router: router)
        }
    }

    /// Sends `initialize`.
    ///
    /// - Returns: The answer of the agent.
    /// - Throws: Whatever `initialize` threw.
    @discardableResult
    func initialize() async throws -> InitializeResponse {
        try await model.initialize(makeInitializeRequest())
    }

    /// Opens one session.
    ///
    /// - Returns: The model of the session.
    /// - Throws: Whatever `session/new` threw.
    func openSession() async throws -> SessionModel {
        try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: cwd)))
    }

    /// Runs one turn: opens a session, sends the prompt, and waits until the
    /// agent reports `idle`.
    ///
    /// - Throws: Whatever `session/new` or the prompt threw, or
    ///   `CancellationError` when the test time limit cancels the wait.
    func runTurn() async throws {
        let session = try await openSession()
        _ = try await session.prompt([textBlock(prompt)])
        try await waitUntil {
            guard case .idle = session.agentState else { return false }
            return true
        }
    }

    /// Sends each request of one whole session: `initialize`, the turn, and
    /// `session/close`.
    ///
    /// - Throws: Whatever `initialize` or the turn threw.
    func runWholeSession() async throws {
        try await initialize()
        try await runTurn()
        try await closeTheTurnSession()
    }

    /// Sends `session/close` for the session the turn opened. The answer of
    /// the agent does not matter here: each test reads the telemetry of the
    /// close, and not its result.
    ///
    /// - Throws: A requirement failure when the turn opened no session.
    func closeTheTurnSession() async throws {
        let session = try #require(model.session(for: testSession))
        try? await model.close(session)
    }

    /// Sends `initialize`, opens one session, and sends `session/close` for
    /// it, with no turn between.
    ///
    /// - Throws: Whatever `initialize` or `session/new` threw.
    func openAndCloseOneSession() async throws {
        try await initialize()
        _ = try await openSession()
        try await closeTheTurnSession()
    }

    /// Gives the `_meta` that the agent got for one method.
    ///
    /// - Parameter method: The ACP method.
    /// - Returns: The `_meta` of each message of that method, in arrival
    ///   order.
    func receivedMeta(of method: String) -> [JSONValue?] {
        builtAgents.elements.last?.receivedMeta(of: method) ?? []
    }

    /// Closes the connection.
    func teardown() async {
        await model.connection?.close()
        withExtendedLifetime(agentConnection) {}
    }
}
