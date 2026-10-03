import FoundationModelsACP
import Observation

/// The observable state of one ACP connection to an agent.
///
/// The model makes the connection over a transport, shows its life in
/// ``state``, and holds the ``SessionModel`` of each open session in
/// ``openSessions``. When the connection closes, for each reason, the model
/// closes each open session model, which cancels each pending permission
/// request and elicitation of that session, and empties ``openSessions``.
///
/// A request-scoped elicitation has no session, so the connection model holds
/// it in ``pendingElicitations`` while the client request that it names is in
/// flight. The end of that request, the close of the connection, and a new
/// connection each cancel it.
///
/// The model reads the close from `ClientSideConnection.closed`. That value
/// comes one time, after each inbound handler of the served `Client` ended,
/// so the close of the session models has no race with a handler that still
/// runs.
///
/// Each session model that the connection makes gets the coalescing cadence
/// and the clock given to ``init(coalescingCadence:clock:logger:)``.
@MainActor @Observable
public final class ConnectionModel {
    /// The state of the connection. The model starts in
    /// ``ConnectionState/disconnected``.
    public private(set) var state: ConnectionState = .disconnected

    /// The model of each open session, keyed by its session id.
    public private(set) var openSessions: [SessionId: SessionModel] = [:]

    /// The answer of the agent to the last `initialize` of the open
    /// connection, or `nil` before ``initialize(_:)`` succeeds. Each new
    /// connection sets it back to `nil`.
    public internal(set) var initializeResponse: InitializeResponse?

    /// The auth state of the connection. It is ``AuthState/unknown`` before
    /// ``initialize(_:)`` succeeds, and each new connection sets it back to
    /// ``AuthState/unknown``.
    public internal(set) var authState: AuthState = .unknown

    /// The open connection, or `nil` when no connection is open. A close
    /// that comes from an earlier connection changes nothing.
    @ObservationIgnored private(set) var connection: ClientSideConnection?

    /// The pending request-scoped elicitations and the continuation of each
    /// one. The queue is observable, so a read of ``pendingElicitations``
    /// tracks it.
    @ObservationIgnored let elicitations = PendingRequestQueue<PendingElicitation, CreateElicitationResponse>(
        cancelledResponse: ElicitationResponseWire.cancelResponse
    )

    /// The task that reads the outgoing-request events of the open
    /// connection, or `nil` when no connection is open. It cancels each
    /// pending elicitation whose request finished.
    @ObservationIgnored private var requestWatch: Task<Void, Never>?

    /// The cadence between coalesced flushes of each session model that this
    /// connection makes.
    @ObservationIgnored private let coalescingCadence: Duration

    /// The clock that schedules the coalesced flushes of each session model
    /// that this connection makes.
    @ObservationIgnored private let clock: any Clock<Duration>

    /// The diagnostic sink of the connection when ``connect(over:logger:client:)``
    /// gets no logger of its own.
    @ObservationIgnored private let logger: ACPLogger

    /// Makes a model with no connection and no open session.
    ///
    /// - Parameters:
    ///   - coalescingCadence: The cadence between coalesced flushes of each
    ///     session model that the connection makes. `.zero` applies each
    ///     chunk at once.
    ///   - clock: The clock that schedules the coalesced flushes of each
    ///     session model that the connection makes. Tests give a manual
    ///     clock, so they do not read the wall clock.
    ///   - logger: The diagnostic sink of the connection; never stdout.
    public init(
        coalescingCadence: Duration = SessionModel.defaultCoalescingCadence,
        clock: any Clock<Duration> = ContinuousClock(),
        logger: ACPLogger = .disabled
    ) {
        self.coalescingCadence = coalescingCadence
        self.clock = clock
        self.logger = logger
    }

    // MARK: - Connection

    /// Connects over `transport` and gives the connection that drives the
    /// agent.
    ///
    /// ``state`` is ``ConnectionState/connecting`` while the call makes the
    /// connection, and ``ConnectionState/connected`` when the call returns.
    /// When the agent closes its side, or the host calls `close()` on the
    /// connection, ``state`` becomes ``ConnectionState/disconnected``. When
    /// the read from the agent fails, ``state`` becomes
    /// ``ConnectionState/failed(_:)`` with the error. A failed write does not
    /// close the connection; only the request of that write fails.
    ///
    /// The connection serves the `Client` that `wrap` returns. `wrap` gets
    /// the router of this model, which routes the calls of the agent to the
    /// models, and runs one time, on the main actor, before the connection
    /// is made. A host that must answer the agent itself returns a `Client`
    /// in front of the router. Such a wrapper must forward `sessionUpdate(_:)`
    /// and `elicitationComplete(_:)` to the router: the connection gives each
    /// of them one time, to the served `Client` only, so a wrapper that drops
    /// one leaves the models stale.
    ///
    /// The model never reconnects on its own. After a close, the host can
    /// call this method again with a new transport. Each call forgets the
    /// `initialize` answer and the auth state of the last connection, so
    /// each capability flag is `false` until ``initialize(_:)`` runs again.
    /// Each call also cancels each pending elicitation of the last
    /// connection, because the model no longer reads the events of its
    /// requests.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional transport to run over.
    ///   - logger: The diagnostic sink of this connection, or `nil` for the
    ///     logger given to ``init(coalescingCadence:clock:logger:)``; never
    ///     stdout.
    ///   - wrap: Builds the served `Client` from the router of this model.
    /// - Returns: The client-side connection, ready to drive the agent.
    public func connect(
        over transport: any ACPTransport,
        logger: ACPLogger? = nil,
        client wrap: @escaping @Sendable @MainActor (any Client) -> any Client = { $0 }
    ) async -> ClientSideConnection {
        state = .connecting
        initializeResponse = nil
        authState = .unknown
        stopWatchingRequests()
        let connectionLogger = logger ?? self.logger
        // The factory of the connection is not main-actor isolated, so the
        // served client is built here, on the main actor, and given ready.
        let served = wrap(ModelClient(model: self, logger: connectionLogger))
        let opened = await ClientSideConnection(stream: transport, logger: connectionLogger) { _ in served }
        connection = opened
        requestWatch = watchOutgoingRequests(of: opened)
        state = .connected
        // The wait for the close runs in a task of its own, never in an
        // inbound handler: the close reason comes only after each inbound
        // handler ended, so a wait inside one never ends.
        Task { [weak self] in
            let reason = await opened.closed
            self?.connectionDidClose(opened, because: reason)
        }
        return opened
    }

    /// Records the close of a connection: sets ``state`` from the reason,
    /// cancels each pending request-scoped elicitation, and closes each open
    /// session model.
    ///
    /// - Parameters:
    ///   - closed: The connection that closed.
    ///   - reason: The reason of the close.
    private func connectionDidClose(_ closed: ClientSideConnection, because reason: ConnectionCloseReason) {
        guard closed === connection else { return }
        connection = nil
        state = ConnectionState(closedBecause: reason)
        stopWatchingRequests()
        closeOpenSessions()
    }

    /// Stops the read of the outgoing-request events, and cancels each
    /// pending request-scoped elicitation, whose request can no longer
    /// finish in the eyes of the model.
    private func stopWatchingRequests() {
        requestWatch?.cancel()
        requestWatch = nil
        elicitations.cancelAll()
    }

    /// Closes each open session model and empties ``openSessions``.
    ///
    /// The close of a model cancels each of its pending permission requests
    /// and elicitations.
    private func closeOpenSessions() {
        let closing = openSessions.values
        openSessions.removeAll()
        for session in closing {
            session.markClosed()
        }
    }

    // MARK: - Open sessions

    /// Gives the model of an open session.
    ///
    /// - Parameter sessionId: The id of the session.
    /// - Returns: The model, or `nil` when the session is not open.
    public func session(for sessionId: SessionId) -> SessionModel? {
        openSessions[sessionId]
    }

    /// Makes the model of a session, with the coalescing cadence and the
    /// clock of this connection. The model is not open until ``register(_:)``
    /// adds it.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session.
    ///   - requestSender: The sender of the requests of the session.
    /// - Returns: The model.
    func makeSessionModel(sessionId: SessionId, requestSender: any SessionRequestSender) -> SessionModel {
        SessionModel(
            sessionId: sessionId,
            requestSender: requestSender,
            coalescingCadence: coalescingCadence,
            clock: clock
        )
    }

    /// Adds a session model to ``openSessions``, keyed by its session id. A
    /// model with the same session id goes out of the registry.
    ///
    /// - Parameter model: The model of the open session.
    func register(_ model: SessionModel) {
        openSessions[model.sessionId] = model
    }

    /// Removes the model of a session from ``openSessions``. An id that is
    /// not open changes nothing.
    ///
    /// - Parameter sessionId: The id of the session.
    func unregister(_ sessionId: SessionId) {
        openSessions[sessionId] = nil
    }
}
