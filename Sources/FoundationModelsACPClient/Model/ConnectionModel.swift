import Foundation
import FoundationModelsACP
import FoundationModelsExtras
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
/// ``init(coalescingCadence:clock:now:logger:identitySource:)``, and the diagnostic sink of
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

    /// The SAH object in `_meta.sah` of the last `initialize` answer of the
    /// open connection, or `nil` when the agent has no SAH extensions.
    ///
    /// It is `nil` before ``initialize(_:)`` succeeds, and when the answer has
    /// no valid `_meta.sah`. Each new connection sets it back to `nil`.
    /// ``graphQLEndpoints`` holds its endpoints: the agent-level endpoints at
    /// connect. For the live list, which also holds the endpoints of each
    /// open session, use ``SAHGraphQLClient/endpoints()``.
    public internal(set) var sah: SAH.InitializeMeta? {
        didSet { sahDidChange() }
    }

    /// The GraphQL endpoints of ``sah``, in the form of the client: the
    /// agent-level endpoints at connect. The list is empty when ``sah`` is
    /// `nil`.
    ///
    /// The list does not change until the next ``initialize(_:)``, and it does
    /// not hold the endpoints that the tools of a session add, for example
    /// `kanban`. ``SAHGraphQLClient/endpoints()`` gives the live list. The
    /// list leaves out each endpoint whose scope the client does not know,
    /// and the model logs one diagnostic for it.
    public private(set) var graphQLEndpoints: [SAHGraphQLClient.Endpoint] = []

    /// Sets ``graphQLEndpoints`` from ``sah``. A change of ``sah`` calls it.
    private func sahDidChange() {
        graphQLEndpoints = SAHGraphQLClient.Endpoint.clientEndpoints(of: sah?.graphql ?? [], logger: connectionLogger)
    }

    /// The identity of the person that the last ``initialize(_:)`` sent in
    /// the `_meta` of its request, or `nil` before the first
    /// ``initialize(_:)``. A UI can show it.
    ///
    /// When the caller put an actor under `GraphQLActor.initializeMetaKey`,
    /// it is the actor of the caller. Otherwise it is the actor that
    /// ``identitySource`` gave. A new connection does not clear it.
    public internal(set) var actor: GraphQLActor?

    /// The source of the identity of the person. ``initialize(_:)`` resolves
    /// it one time for each `initialize`.
    @ObservationIgnored let identitySource: any PersonIdentitySource

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

    /// The GraphQL subscriptions of the open connection, or `nil` when no
    /// connection is open. Each connection gets a new table, because a
    /// subscription id is unique only for one connection. The close of the
    /// connection finishes each open subscription with
    /// ``SAHGraphQLError/connectionClosed``.
    @ObservationIgnored private(set) var graphQLSubscriptions: SAHGraphQLSubscriptions?

    /// The extensions of the model: the built-in extensions first, and then
    /// the extensions of the host in the order of ``addExtension(_:)``. The
    /// model keeps one extension for each type.
    @ObservationIgnored private var extensions: [any ClientModelExtension]

    /// The extensions of the last connection, each with its connection
    /// state, or `nil` before the first connect. Each connect replaces it, so
    /// a view that reads ``extensionState(_:)`` sees the new state.
    private(set) var openedExtensions: OpenedExtensions?


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

    /// The one consumer of the ordered event stream of all sessions of the
    /// open connection. It applies each event to the model of its session, in
    /// wire order, so no model reads ahead of another model.
    @ObservationIgnored private var eventConsumer: Task<Void, Never>?

    /// The events of a session that has no model yet, in order. A root
    /// session gets updates before the answer of `session/new` makes its
    /// model. The model gets them when it registers.
    @ObservationIgnored var pendingEvents: [SessionId: [SessionStreamEvent]] = [:]

    /// The sessions with a model that closed. The consumer drops each event
    /// of these, so no traffic reaches a removed child. A new model of the
    /// same session id takes the id out of the set.
    @ObservationIgnored var closedSessionIds = BoundedIDSet<SessionId>(limit: ConnectionModel.closedSessionLimit)

    /// The sessions of which the connection discarded events before the
    /// consumer attached. Their models set ``SessionModel/hasMissedUpdates``.
    @ObservationIgnored private var sessionsWithMissedEvents = BoundedIDSet<SessionId>(
        limit: ConnectionModel.closedSessionLimit
    )

    /// The sessions that have pending events, oldest first. The oldest
    /// session leaves first when the table is over its limit.
    @ObservationIgnored private var pendingOrder = BoundedIDSet<SessionId>(
        limit: SessionUpdateBufferLimits.default.maximumSessions
    )

    /// The most closed sessions and missed sessions that the connection model
    /// remembers.
    static let closedSessionLimit = 1024

    /// The model of each child session, by session id. The tree holds the same
    /// models. This index finds a child at once.
    @ObservationIgnored var childModels: [SessionId: SessionModel] = [:]

    /// The limits on the events that the consumer keeps for sessions with no
    /// model yet. Past a limit, it discards the events of the session and
    /// marks the session as missed.
    @ObservationIgnored private var pendingLimits = SessionUpdateBufferLimits.default {
        didSet { pendingOrder = BoundedIDSet(limit: pendingLimits.maximumSessions) }
    }

    /// A test hook that the consumer awaits before it applies each event, so
    /// a test can hold the consumer at one event.
    @ObservationIgnored var beforeApplyingEvent: (@MainActor (SequencedSessionEvent) async -> Void)?

    /// A test hook that tells that a request handler waits for events that
    /// the consumer did not apply yet.
    @ObservationIgnored var didStartWaitingForEvents: (@MainActor () -> Void)?

    /// The highest wire sequence that the consumer applied, or `nil` before
    /// the first event.
    @ObservationIgnored private(set) var appliedSequence: UInt64?

    /// The callers that wait for the consumer to apply a sequence.
    @ObservationIgnored private let sequenceWaiters = KeyedWaiters<UInt64, Void>(cancelledValue: ())

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
    ///   - identitySource: The source of the identity of the person, which
    ///     ``initialize(_:)`` sends to the agent. The default is
    ///     ``LocalUserIdentitySource``. Only an app with the iCloud
    ///     entitlement can give an `ICloudIdentitySource`.
    public init(
        coalescingCadence: Duration = SessionModel.defaultCoalescingCadence,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = Date.init,
        logger: ACPLogger = .disabled,
        identitySource: any PersonIdentitySource = LocalUserIdentitySource()
    ) {
        self.identitySource = identitySource
        self.coalescingCadence = coalescingCadence
        self.clock = clock
        self.now = now
        self.logger = logger
        connectionLogger = logger
        extensions = BuiltInClientModelExtensions.extensions
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
    /// one leaves the models stale. The wrapper must also give the
    /// `extensionHandlers` of the router as its own: they serve the
    /// `_sah/graphql/*` notifications of a ``SAHGraphQLClient`` over this
    /// model, and each method and notification of each extension that
    /// ``addExtension(_:)`` added. A wrapper that does not forward them
    /// gives no message to an extension.
    ///
    /// Each call makes a new connection state for each extension, before it
    /// calls `wrap`; see ``extensionState(_:)``. The close of the connection
    /// gives the close to each extension one time.
    ///
    /// The model never reconnects on its own. After a close, the host can
    /// call this method again with a new transport. Each call forgets the
    /// `initialize` answer, the SAH object (``sah``), and the auth state of
    /// the last connection, so each capability flag is `false` until
    /// ``initialize(_:)`` runs again.
    /// Each call keeps the method of a successful terminal login, so the
    /// next ``initialize(_:)`` can give ``AuthState/authenticated(_:)``.
    /// Each call also cancels each pending elicitation of the last
    /// connection, because the model no longer reads the events of its
    /// requests.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional transport to run over.
    ///   - logger: The diagnostic sink of this connection, or `nil` for the
    ///     logger given to ``init(coalescingCadence:clock:now:logger:identitySource:)``; never
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
        sah = nil
        authState = .unknown
        hasAdvertisedTerminalAuth = false
        advertisedElicitation = nil
        stopWatchingRequests()
        // The wire numbers of the new connection start at 0 again. The stop
        // above cancelled each pending elicitation, so the queue is empty.
        elicitations.arrivalSpace.reset()
        let connectionLogger = logger ?? self.logger
        self.connectionLogger = connectionLogger
        let subscriptions = SAHGraphQLSubscriptions()
        let generation = connectionGeneration
        let opening = OpenedExtensions(extensions, connectionLogger: connectionLogger) { [weak self] sessionId in
            self?.session(for: sessionId, ofConnection: generation)
        }
        openedExtensions = opening
        // The factory of the connection is not main-actor isolated, so the
        // served client is built here, on the main actor, and given ready.
        let connectionBox = ConnectionBox()
        let served = wrap(
            ModelClient(
                model: self,
                logger: connectionLogger,
                graphQLSubscriptions: subscriptions,
                extensionRegistrations: opening.registrations,
                connectionBox: connectionBox
            )
        )
        let opened = await ClientSideConnection(
            stream: transport,
            logger: connectionLogger,
            bufferLimits: bufferLimits
        ) { _ in served }
        pendingLimits = bufferLimits
        connection = opened
        connectionBox.set(opened)
        graphQLSubscriptions = subscriptions
        requestWatch = watchOutgoingRequests(of: opened)
        startEventConsumer(on: opened)
        state = .connected
        // The wait for the close runs in a task of its own, never in an
        // inbound handler: the close reason comes only after each inbound
        // handler ended, so a wait inside one never ends. The task closes
        // the subscriptions and the extensions of its own connection also
        // when a later connection replaced it in this model.
        Task { [weak self] in
            let reason = await opened.closed
            subscriptions.closeAll()
            opening.didClose()
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
    /// cancels each pending request-scoped elicitation, finishes each open
    /// GraphQL subscription with ``SAHGraphQLError/connectionClosed``, gives
    /// the close to each extension of the connection, and closes each open
    /// session model.
    ///
    /// - Parameters:
    ///   - closed: The connection that closed.
    ///   - reason: The reason of the close.
    private func connectionDidClose(_ closed: ClientSideConnection, because reason: ConnectionCloseReason) {
        guard closed === connection else { return }
        connection = nil
        graphQLSubscriptions?.closeAll()
        graphQLSubscriptions = nil
        openedExtensions?.didClose()
        connectionGeneration += 1
        state = ConnectionState(closedBecause: reason)
        stopWatchingRequests()
        stopEventConsumer()
        closeOpenSessions()
    }

    // MARK: - Extensions

    /// Adds an extension to the model. See ``ClientModelExtension``.
    ///
    /// Each later ``connect(over:logger:bufferLimits:client:)`` makes a new
    /// connection state for the extension, and serves its handlers. Add each
    /// extension before the connect: the connection reads its handlers one
    /// time, when it opens. While a connection is open, the call has no
    /// effect on that connection, and the model logs one diagnostic. The
    /// extension then takes effect at the next connect.
    ///
    /// The model keeps one extension for each type. An extension of a type
    /// that the model already holds replaces the earlier extension in its
    /// position.
    ///
    /// The extensions register their handlers in the order of this call.
    /// When two extensions register the same method or notification, the
    /// later one wins, and the model logs one diagnostic.
    ///
    /// The built-in extensions of the model come before each extension of
    /// this call. They take the `_mcp_server_status` and the
    /// `_mail_delivery_paused` updates of each session, so an extension of
    /// this call does not get those updates. It gets each other update.
    ///
    /// - Parameter clientExtension: The extension to add.
    public func addExtension(_ clientExtension: some ClientModelExtension) {
        let key = ObjectIdentifier(type(of: clientExtension))
        if let position = extensions.firstIndex(where: { ObjectIdentifier(type(of: $0)) == key }) {
            extensions[position] = clientExtension
        } else {
            extensions.append(clientExtension)
        }
        guard connection != nil || state == .connecting else { return }
        connectionLogger.log(
            "ConnectionModel: the extension \(type(of: clientExtension)) was added while a connection is open; "
                + "it takes effect at the next connect"
        )
    }

    /// Gives the connection state of an extension for the last connection.
    ///
    /// Each ``connect(over:logger:bufferLimits:client:)`` makes a new state
    /// for each extension, so the call gives a new state after each connect.
    /// After a close, the call gives the state of the closed connection until
    /// the next connect.
    ///
    /// - Parameter extensionType: The type of the extension.
    /// - Returns: The connection state, or `nil` before the first connect and
    ///   when the last connect had no extension of that type.
    public func extensionState<Extension: ClientModelExtension>(
        _ extensionType: Extension.Type
    ) -> Extension.ConnectionState? {
        openedExtensions?.state(of: extensionType)
    }

    /// Gives the model of a session of one connection: an open session, or a
    /// child session at any level under one.
    ///
    /// ``ClientModelExtensionContext/session(for:)`` reads it, so a handler
    /// of an earlier connection finds no session of a later one.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session.
    ///   - generation: The ``connectionGeneration`` of the connection.
    /// - Returns: The model, or `nil` when the session is not open, and when
    ///   `generation` is not the generation of the open connection.
    func session(for sessionId: SessionId, ofConnection generation: Int) -> SessionModel? {
        guard generation == connectionGeneration else { return nil }
        return session(for: sessionId) ?? childSession(for: sessionId)
    }

    // MARK: - Ordered events

    /// Starts the one consumer of the ordered event stream of a connection.
    ///
    /// - Parameter connection: The connection whose sessions to follow.
    private func startEventConsumer(on connection: ClientSideConnection) {
        eventConsumer?.cancel()
        clearPendingState()
        closedSessionIds.removeAll()
        appliedSequence = nil
        let subscription = connection.subscribeToAllSessions()
        sessionsWithMissedEvents.removeAll()
        for id in subscription.sessionsWithMissedEvents {
            sessionsWithMissedEvents.insert(id)
        }
        let events = subscription.events
        eventConsumer = Task { @MainActor [weak self] in
            for await event in events {
                if let hook = self?.beforeApplyingEvent {
                    await hook(event)
                }
                self?.apply(event)
            }
            self?.eventStreamDidEnd()
        }
    }

    /// Forgets the events of sessions with no model, and the index of the
    /// child models.
    private func clearPendingState() {
        pendingEvents.removeAll()
        pendingOrder.removeAll()
        childModels.removeAll()
    }

    /// Takes a child model out of the index, when the index holds that model.
    ///
    /// - Parameter model: The model to take out.
    func removeFromIndex(_ model: SessionModel) {
        if childModels[model.sessionId] === model {
            childModels[model.sessionId] = nil
        }
    }

    /// Stops the consumer, and lets each waiter go.
    private func stopEventConsumer() {
        eventConsumer?.cancel()
        eventConsumer = nil
        clearPendingState()
        releaseSequenceWaiters()
    }

    /// Applies one event to the model of its session.
    ///
    /// A closed session drops its events. A session with no model yet keeps
    /// its events in order until its model registers.
    ///
    /// - Parameter event: The event, in wire order.
    private func apply(_ event: SequencedSessionEvent) {
        let sessionId = event.sessionId
        if let model = session(for: sessionId) ?? childSession(for: sessionId) {
            model.receive(event.event)
        } else if !closedSessionIds.contains(sessionId) {
            keepPending(event.event, of: sessionId)
        }
        appliedSequence = event.sequence
        resumeSequenceWaiters()
    }

    /// Keeps an event of a session that has no model yet. Past the limits it
    /// discards the events of the session and marks the session as missed.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - sessionId: The session of the event.
    private func keepPending(_ event: SessionStreamEvent, of sessionId: SessionId) {
        if pendingEvents[sessionId] == nil {
            // The oldest session leaves first, because a session that gets a
            // model soon is one of the newest.
            if let oldest = pendingOrder.insert(sessionId) {
                pendingEvents[oldest] = nil
                sessionsWithMissedEvents.insert(oldest)
            }
        }
        pendingEvents[sessionId, default: []].append(event)
        if pendingEvents[sessionId, default: []].count > pendingLimits.maximumUpdatesPerSession {
            pendingEvents[sessionId] = nil
            pendingOrder.remove(sessionId)
            sessionsWithMissedEvents.insert(sessionId)
        }
    }

    /// Ends the replay and the taps of each open model when the connection
    /// ended the event stream, and lets each waiter go.
    private func eventStreamDidEnd() {
        eventConsumer = nil
        for session in openSessions {
            session.eventStreamDidEnd()
        }
        releaseSequenceWaiters()
    }

    /// Gives a model the events that it missed before it registered, and the
    /// mark of discarded events.
    ///
    /// - Parameter model: The model that was just made.
    func attachToEvents(_ model: SessionModel) {
        model.isStreamAttached = true
        closedSessionIds.remove(model.sessionId)
        if sessionsWithMissedEvents.remove(model.sessionId) {
            model.hasMissedUpdates = true
        }
        pendingOrder.remove(model.sessionId)
        for event in pendingEvents.removeValue(forKey: model.sessionId) ?? [] {
            model.receive(event)
        }
    }

    /// Records that the model of a session closed, so its later events drop.
    /// A newer model of the same session id keeps the id live.
    ///
    /// - Parameter model: The closed model.
    func sessionDidClose(_ model: SessionModel) {
        let sessionId = model.sessionId
        removeFromIndex(model)
        pendingEvents[sessionId] = nil
        pendingOrder.remove(sessionId)
        // A newer model of the same session takes over the events.
        guard childModels[sessionId] == nil, session(for: sessionId) == nil else { return }
        closedSessionIds.insert(sessionId)
    }

    /// Waits until the consumer applied the events of the wire up to a
    /// sequence. It returns at once when the consumer already did, when the
    /// consumer ended, and when the calling task is cancelled.
    ///
    /// - Parameter sequence: The sequence to wait for.
    func waitUntilApplied(_ sequence: UInt64) async {
        guard eventConsumer != nil, appliedSequence.map({ $0 < sequence }) ?? true else { return }
        await sequenceWaiters.wait(for: sequence, onSuspend: { didStartWaitingForEvents?() })
    }

    /// Lets each waiter go whose sequence the consumer applied.
    private func resumeSequenceWaiters() {
        guard let applied = appliedSequence else { return }
        sequenceWaiters.resumeAll(keysWhere: { $0 <= applied }, with: ())
    }

    /// Lets each waiter go, because no event comes any more.
    private func releaseSequenceWaiters() {
        sequenceWaiters.resumeAll(keysWhere: { _ in true }, with: ())
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
    /// the wall clock, the diagnostic sink, and a new session state for each
    /// extension of this connection. Before the first connect, the model gets
    /// a session state for each built-in extension only. The model is not
    /// open until ``register(_:)`` adds it.
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
            logger: connectionLogger,
            extensionFactories: openedExtensions?.sessionFactories ?? BuiltInClientModelExtensions.sessionFactories
        )
        model.sessionInfoDidChange = { [weak self] sessionId, info in
            self?.patchListedSession(sessionId, with: info)
        }
        model.owner = self
        model.subagentDidChange = { [weak self] parent, announcement in
            self?.applySubagent(announcement, under: parent)
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
