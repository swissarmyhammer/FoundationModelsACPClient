import Foundation
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
/// Each session model that the connection makes gets the coalescing cadence,
/// the clock, and the wall clock given to
/// ``init(coalescingCadence:clock:now:logger:)``, and the diagnostic sink of
/// the connection.
@MainActor @Observable
public final class ConnectionModel {
    /// The state of the connection. The model starts in
    /// ``ConnectionState/disconnected``.
    public internal(set) var state: ConnectionState = .disconnected

    /// The model of each open session, in registration order.
    ///
    /// The list holds one model for each session id, so a SwiftUI view can
    /// use `ForEach(connection.openSessions)` and open one window for each
    /// new model. A new session goes at the end. A model for a session that
    /// the list already holds replaces the earlier model in its position. The
    /// close of a session removes its model, and the other models keep their
    /// order. ``session(for:)`` finds the model of a session id.
    public private(set) var openSessions: [SessionModel] = []

    /// The position of each model of ``openSessions``, keyed by its session
    /// id. ``register(_:)``, ``unregister(_:)``, and the close of the
    /// connection keep it in agreement with ``openSessions``, so a lookup by
    /// id needs no search of the list.
    @ObservationIgnored private var openSessionPositions: [SessionId: Int] = [:]

    /// The sessions that the `session/list` pages of the last refresh gave,
    /// in page order. ``refreshSessions(cwd:)`` replaces the list,
    /// ``loadMoreSessions()`` appends to it, ``deleteSession(_:)`` removes
    /// an item, and a `session_info_update` of an open session patches its
    /// item.
    ///
    /// The list holds one item for each session id. When a page gives a
    /// session id that the list already holds, the new item replaces the
    /// earlier item in its position, and the model logs one warning.
    public internal(set) var sessions: [SessionInfo] = []

    /// The cursor of the next `session/list` page, or `nil` when the last
    /// page arrived or no refresh ran.
    var sessionListCursor: SessionListCursor?

    /// The working-directory filter of the last refresh. Each load of more
    /// sessions sends it again.
    @ObservationIgnored var sessionListWorkingDirectory: AbsolutePath?

    /// The generation of the session list. The start of each refresh and
    /// each page that lands change it, so a page whose request started in
    /// an earlier generation is discarded.
    @ObservationIgnored var sessionListGeneration = 0

    /// The answer of the agent to the last `initialize` of the open
    /// connection, or `nil` before ``initialize(_:)`` succeeds. Each new
    /// connection sets it back to `nil`. Its auth methods hold one method for
    /// each method id; see ``authMethods``.
    public internal(set) var initializeResponse: InitializeResponse?

    /// The auth state of the connection. It is ``AuthState/unknown`` before
    /// ``initialize(_:)`` succeeds, and each new connection sets it back to
    /// ``AuthState/unknown``.
    ///
    /// ``AuthState/required(_:)`` also comes from a `-32000`
    /// (`authentication_required`) answer of the agent to a session request
    /// or a list request of the model, or to a prompt or a configuration
    /// change of a session model of the open connection. That answer can
    /// come after a successful login too, for example when the login
    /// expired. A later successful ``login(_:)`` gives
    /// ``AuthState/authenticated(_:)`` again.
    ///
    /// A successful ``loginWithTerminal(_:runner:)`` gives
    /// ``AuthState/reconnectRequired(_:)``. The ``initialize(_:)`` of the
    /// next connection then gives ``AuthState/authenticated(_:)``.
    public internal(set) var authState: AuthState = .unknown

    /// The `terminal` auth method whose terminal login succeeded, or `nil`
    /// when there is none. The login does not authenticate the connection
    /// that was open, so the model keeps the method across
    /// ``connect(over:logger:bufferLimits:client:)`` until the next
    /// ``initialize(_:)`` succeeds.
    @ObservationIgnored var pendingTerminalLogin: AuthMethodId?

    /// Tells whether the last successful ``initialize(_:)`` sent
    /// `capabilities.auth.terminal`. The agent can list a `terminal` auth
    /// method only when the client sent it. It is `false` before
    /// ``initialize(_:)`` succeeds, and each new connection sets it back to
    /// `false`.
    @ObservationIgnored var hasAdvertisedTerminalAuth = false

    /// The `elicitation` capability that the last successful
    /// ``initialize(_:)`` sent, or `nil` when it sent none. It is `nil`
    /// before ``initialize(_:)`` succeeds, and each new connection sets it
    /// back to `nil`. ``refusedElicitationReason(for:)`` reads it.
    @ObservationIgnored var advertisedElicitation: ElicitationCapabilities?

    /// The open connection, or `nil` when no connection is open. A close
    /// that comes from an earlier connection changes nothing.
    @ObservationIgnored private(set) var connection: ClientSideConnection?

    /// The generation of the connection: each connect and each recorded
    /// close add 1 to it. A request-scoped elicitation reads it before and
    /// after its wait, so a record of a withdrawal on an earlier connection
    /// never comes into ``withdrawnRequests`` of a later one.
    @ObservationIgnored private(set) var connectionGeneration = 0

    /// The pending request-scoped elicitations and the continuation of each
    /// one. The queue is observable, so a read of ``pendingElicitations``
    /// tracks it.
    @ObservationIgnored let elicitations = PendingRequestQueue<PendingElicitation, CreateElicitationResponse>(
        cancelledResponse: ElicitationResponseWire.cancelResponse
    )

    /// The id of the pending request that the user brought to the front, or
    /// `nil` when the user did not select one.
    ///
    /// ``bringToFront(_:)`` sets it. It becomes `nil` when its request
    /// resolves, and so also at a close and at a new connection, which cancel
    /// each pending request. It is a pointer into ``pendingRequests``: it does
    /// not change the order of that list. ``frontRequest`` gives the request
    /// to show.
    public internal(set) var frontRequestID: PendingRequest.ID?

    /// The request-scoped url-mode elicitations that the user accepted and
    /// whose `elicitation/complete` notification did not come yet, in accept
    /// order.
    ///
    /// ``acceptElicitation(_:content:)`` of a url-mode elicitation answers the
    /// agent and moves the item from ``pendingElicitations`` to this list,
    /// with the same id. The `elicitation/complete` of the agent, a call of
    /// ``stopWaiting(_:)``, the finish of the client request that the item
    /// names, the close of the connection and a new connection remove it.
    /// None of them sends a message to the agent, because the agent already
    /// has the answer.
    public internal(set) var awaitingURLCompletions: [PendingElicitation] = []

    /// The request-scoped elicitations that the agent withdrew with
    /// `$/cancel_request`, each with the reason of the agent, in withdrawal
    /// order.
    ///
    /// A UI shows these records so that the user knows why a question went
    /// away, and removes each one with ``dismissWithdrawn(_:)``. Only a
    /// `$/cancel_request` of the agent makes a record: an answer of the user,
    /// the finish of the named client request and a close make none. The
    /// close of the connection and a new connection make the list empty.
    ///
    /// The change comes in two steps. The elicitation leaves
    /// ``pendingRequests`` first, and its record comes into this list in a
    /// later main-actor step, when the task of the request resumes. A UI must
    /// not expect the two changes in one observation.
    public internal(set) var withdrawnRequests: [WithdrawnRequest] = []

    /// The task that reads the outgoing-request events of the open
    /// connection, or `nil` when no connection is open. It cancels each
    /// pending elicitation whose request finished.
    @ObservationIgnored private var requestWatch: Task<Void, Never>?

    /// The queue that runs the `session/resume` calls of one session one
    /// after the other, keyed by session id. Two resumes of one session that
    /// overlap would share one replay state.
    @ObservationIgnored let resumeTurns = KeyedTurnQueue<SessionId>()

    /// The sessions whose `session/new` answer arrived and whose model is not
    /// registered yet. The router waits for such a session, so a request of
    /// the agent directly after the answer is not answered with cancel.
    @ObservationIgnored let openingSessions = OpeningSessions()

    /// A test seam: it runs after the answer of a `session/new` request and
    /// before ``newSession(_:)`` registers the model of the session. It is
    /// `nil`, and does nothing, outside the tests. A test holds it to fix the
    /// order of the register and a request of the agent.
    @ObservationIgnored var beforeRegisteringNewSession: (@MainActor (SessionId) async -> Void)?

    /// A test seam: it runs after the wait of a request-scoped elicitation
    /// ends and before the model decides on its record in
    /// ``withdrawnRequests``. It is `nil`, and does nothing, outside the
    /// tests. A test holds it to make a new connection in that window.
    @ObservationIgnored var afterRequestScopedElicitationWait: (@MainActor () async -> Void)?

    /// The cadence between coalesced flushes of each session model that this
    /// connection makes.
    @ObservationIgnored private let coalescingCadence: Duration

    /// The clock that schedules the coalesced flushes of each session model
    /// that this connection makes.
    @ObservationIgnored private let clock: any Clock<Duration>

    /// The wall clock that gives the start time and the end time of each
    /// transcript entry of each session model that this connection makes.
    @ObservationIgnored private let now: @Sendable () -> Date

    /// The diagnostic sink of the connection when
    /// ``connect(over:logger:bufferLimits:client:)`` gets no logger of its
    /// own.
    @ObservationIgnored private let logger: ACPLogger

    /// The diagnostic sink of the last connection: the logger given to
    /// ``connect(over:logger:bufferLimits:client:)``, or ``logger`` when that
    /// call got none. Before the first connection, it is ``logger``.
    @ObservationIgnored private(set) var connectionLogger: ACPLogger

    /// Makes a model with no connection and no open session.
    ///
    /// - Parameters:
    ///   - coalescingCadence: The cadence between coalesced flushes of each
    ///     session model that the connection makes. `.zero` applies each
    ///     chunk at once.
    ///   - clock: The clock that schedules the coalesced flushes of each
    ///     session model that the connection makes. Tests give a manual
    ///     clock, so they do not read the wall clock.
    ///   - now: The wall clock that gives the start time and the end time of
    ///     each transcript entry of each session model that the connection
    ///     makes. Tests give a manual wall clock, so they do not read the
    ///     system date.
    ///   - logger: The diagnostic sink of the connection; never stdout.
    public init(
        coalescingCadence: Duration = SessionModel.defaultCoalescingCadence,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = Date.init,
        logger: ACPLogger = .disabled
    ) {
        self.coalescingCadence = coalescingCadence
        self.clock = clock
        self.now = now
        self.logger = logger
        connectionLogger = logger
        elicitations.didRemove = { [weak self] id in
            self?.clearFrontRequest(ifItIs: id)
        }
    }

    // MARK: - Connection

    /// Connects over `transport` and gives the connection that drives the
    /// agent.
    ///
    /// ``state`` is ``ConnectionState/connecting`` while the call makes the
    /// connection, and ``ConnectionState/connected`` when the call returns.
    /// When the agent closes its side, or the host calls ``disconnect()`` or
    /// `close()` on the connection, ``state`` becomes
    /// ``ConnectionState/disconnected``. When the read from the agent fails,
    /// ``state`` becomes ``ConnectionState/failed(_:)`` with the error. A
    /// failed write does not close the connection; only the request of that
    /// write fails.
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
    /// Each call keeps the method of a successful terminal login, so the
    /// next ``initialize(_:)`` can give ``AuthState/authenticated(_:)``.
    /// Each call also cancels each pending elicitation of the last
    /// connection, because the model no longer reads the events of its
    /// requests.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional transport to run over.
    ///   - logger: The diagnostic sink of this connection, or `nil` for the
    ///     logger given to ``init(coalescingCadence:clock:now:logger:)``; never
    ///     stdout.
    ///   - bufferLimits: The limits on the `session/update` notifications that
    ///     the connection keeps for a session with no subscriber, for example
    ///     the updates that come before a `session/new` response. Past a
    ///     limit, the model of that session gets
    ///     ``SessionModel/hasMissedUpdates``.
    ///   - wrap: Builds the served `Client` from the router of this model.
    /// - Returns: The client-side connection, ready to drive the agent.
    public func connect(
        over transport: any ACPTransport,
        logger: ACPLogger? = nil,
        bufferLimits: SessionUpdateBufferLimits = .default,
        client wrap: @escaping @Sendable @MainActor (any Client) -> any Client = { $0 }
    ) async -> ClientSideConnection {
        state = .connecting
        connectionGeneration += 1
        initializeResponse = nil
        authState = .unknown
        hasAdvertisedTerminalAuth = false
        advertisedElicitation = nil
        stopWatchingRequests()
        // The wire numbers of the new connection start at 0 again. The stop
        // above cancelled each pending elicitation, so the queue is empty.
        elicitations.arrivalSpace.reset()
        let connectionLogger = logger ?? self.logger
        self.connectionLogger = connectionLogger
        // The factory of the connection is not main-actor isolated, so the
        // served client is built here, on the main actor, and given ready.
        let served = wrap(ModelClient(model: self, logger: connectionLogger))
        let opened = await ClientSideConnection(
            stream: transport,
            logger: connectionLogger,
            bufferLimits: bufferLimits
        ) { _ in served }
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

    /// Closes the open connection from the client side, and waits until the
    /// model recorded the close.
    ///
    /// When the call returns, the model recorded the close: ``state`` is
    /// ``ConnectionState/disconnected`` (or ``ConnectionState/failed(_:)``
    /// when the read from the agent failed first), ``openSessions`` is empty,
    /// each session model that was open is closed, and each pending
    /// permission request, session elicitation and request-scoped
    /// elicitation is cancelled. Thus a host can read the state at once.
    ///
    /// The call does not send `session/close` for each open session: the
    /// agent frees its sessions when the connection ends. A host that must
    /// close a session cleanly calls ``close(_:)`` for it before this call.
    ///
    /// The close stops the read of the transport, which ends its byte
    /// stream. The agent then sees the end of its input. For an
    /// ``AgentProcess`` transport, the end of that stream ends the agent
    /// process. For an `InMemoryTransport` pair, the stream of the agent end
    /// ends too, so an in-process agent connection closes with
    /// `ConnectionCloseReason.endOfInput`.
    ///
    /// With no open connection, the call returns at once and changes
    /// nothing. After this call, ``connect(over:logger:bufferLimits:client:)``
    /// can make a new connection.
    public func disconnect() async {
        guard let connection else { return }
        await connection.close()
        let reason = await connection.closed
        connectionDidClose(connection, because: reason)
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
        connectionGeneration += 1
        state = ConnectionState(closedBecause: reason)
        stopWatchingRequests()
        closeOpenSessions()
    }

    /// Stops the read of the outgoing-request events, cancels each pending
    /// request-scoped elicitation, whose request can no longer finish in the
    /// eyes of the model, and stops the wait for each accepted url-mode
    /// elicitation.
    private func stopWatchingRequests() {
        requestWatch?.cancel()
        requestWatch = nil
        elicitations.cancelAll()
        awaitingURLCompletions.removeAll()
        // An empty list stays as it is, so an observer sees no change.
        if !withdrawnRequests.isEmpty {
            withdrawnRequests.removeAll()
        }
    }

    /// Closes each open session model and empties ``openSessions``.
    ///
    /// The close of a model cancels each of its pending permission requests
    /// and elicitations.
    private func closeOpenSessions() {
        let closing = openSessions
        openSessions.removeAll()
        openSessionPositions.removeAll()
        for session in closing {
            session.markClosed()
        }
    }

    /// Gives `signal` when the connection wrote the response of the inbound
    /// request that the calling task handles, or when the connection will
    /// never write that response.
    ///
    /// Call this on the task of an inbound request, before its handler
    /// returns: the connection finds the request through that task. The
    /// connection gives `signal` exactly one time. With no open connection, no
    /// response follows, so `signal` goes at once.
    ///
    /// - Parameter signal: The signal to give.
    func signalAfterCurrentResponse(_ signal: @escaping @Sendable () -> Void) {
        guard let connection else {
            signal()
            return
        }
        connection.afterRespondingToCurrentRequest({ signal() }, onDiscard: signal)
    }

    // MARK: - Open sessions

    /// Gives the model of an open session.
    ///
    /// The call always reads ``openSessions``, also when the session is not
    /// open. Thus an observer of the call sees the register of the session
    /// later, for example a SwiftUI view that waits for a session to open.
    ///
    /// - Parameter sessionId: The id of the session.
    /// - Returns: The model, or `nil` when the session is not open.
    public func session(for sessionId: SessionId) -> SessionModel? {
        let sessions = openSessions
        guard let position = openSessionPositions[sessionId] else { return nil }
        return sessions[position]
    }

    /// Makes the model of a session, with the coalescing cadence, the clock,
    /// the wall clock, and the diagnostic sink of this connection. The model
    /// is not open until ``register(_:)`` adds it.
    ///
    /// The model tells this connection model each change of its
    /// ``SessionModel/sessionInfo``, so the item of the session in
    /// ``sessions`` shows the change.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session.
    ///   - requestSender: The sender of the requests of the session.
    /// - Returns: The model.
    func makeSessionModel(sessionId: SessionId, requestSender: any SessionRequestSender) -> SessionModel {
        let model = SessionModel(
            sessionId: sessionId,
            requestSender: requestSender,
            coalescingCadence: coalescingCadence,
            clock: clock,
            now: now,
            logger: connectionLogger
        )
        model.sessionInfoDidChange = { [weak self] sessionId, info in
            self?.patchListedSession(sessionId, with: info)
        }
        return model
    }

    /// Adds a session model at the end of ``openSessions``. When the list
    /// already holds a model with the same session id, the new model
    /// replaces that model in its position, and the list does not get
    /// longer.
    ///
    /// - Parameter model: The model of the open session.
    func register(_ model: SessionModel) {
        if let position = openSessionPositions[model.id] {
            openSessions[position] = model
        } else {
            openSessionPositions[model.id] = openSessions.endIndex
            openSessions.append(model)
        }
    }

    /// Removes the model of a session from ``openSessions``. The other
    /// models keep their order. An id that is not open changes nothing.
    ///
    /// - Parameter sessionId: The id of the session.
    func unregister(_ sessionId: SessionId) {
        guard let position = openSessionPositions.removeValue(forKey: sessionId) else { return }
        openSessions.remove(at: position)
        for later in openSessions.indices[position...] {
            openSessionPositions[openSessions[later].id] = later
        }
    }
}
