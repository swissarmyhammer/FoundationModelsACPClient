import FoundationModelsACP

/// An extension of the client models: it serves the `_` extension methods
/// and notifications of the agent, keeps its own state for each connection
/// and for each session, and takes the session updates that it knows.
///
/// A host adds an extension with ``ConnectionModel/addExtension(_:)``
/// before ``ConnectionModel/connect(over:logger:bufferLimits:client:)``.
/// Each connect makes a new connection state for each extension with
/// ``makeConnectionState()``, and then asks each extension to register its
/// handlers with ``registerHandlers(into:context:)``. The host reads the
/// state of the current connection with
/// ``ConnectionModel/extensionState(_:)``.
///
/// Each ``SessionModel`` that the connection makes, also the model of a
/// child session, makes a new session state for each extension with
/// ``makeSessionState(for:)``. The model gives each `session/update` of the
/// session to ``apply(_:to:)`` of each extension, in the order of
/// ``ConnectionModel/addExtension(_:)``, before its own rules. The host reads
/// the state of a session with ``SessionModel/extensionState(_:)``.
///
/// The protocol has two isolation parts:
///
/// - The handlers run in the connection, not on the main actor. A
///   notification handler runs in the read loop of the connection, in
///   arrival order, so it must return promptly. A request handler runs in its
///   own task, so it can wait.
/// - The connection state, the session state and the hooks
///   ``didInitialize(_:state:)``, ``didClose(state:)``, ``apply(_:to:)`` and
///   ``didStartSession(state:mcpServers:)`` are on the main actor. A handler
///   that changes main-actor state hops to the main actor, for example with
///   `await MainActor.run { context.connectionState.count += 1 }`.
///
/// The protocol itself is not main-actor isolated. Thus a conforming type
/// writes `@MainActor` on its ``makeConnectionState()``,
/// ``makeSessionState(for:)``, ``didInitialize(_:state:)``,
/// ``didClose(state:)``, ``apply(_:to:)`` and
/// ``didStartSession(state:mcpServers:)``.
///
/// The model keeps one extension for each type: the type of the extension
/// is the key of its state.
public protocol ClientModelExtension: Sendable {
    /// The state of the extension for one connection.
    ///
    /// Use a `@MainActor @Observable` class, so a view can show the state.
    /// When the handlers must change the state off the main actor, use a
    /// `Sendable` class with a `Mutex`.
    associatedtype ConnectionState: AnyObject

    /// Makes the state of the extension for a new connection.
    ///
    /// Each connect calls it one time, before the connection opens.
    ///
    /// - Returns: The new connection state.
    @MainActor func makeConnectionState() -> ConnectionState

    /// The state of the extension for one session.
    ///
    /// Use a `@MainActor @Observable` class, so a view can show the state.
    associatedtype SessionState: AnyObject

    /// Makes the state of the extension for one session model.
    ///
    /// The connection calls it one time for each session model that it
    /// makes: the model of a `session/new`, of a `session/resume` of a
    /// session that is not open, and of a child session. A replay of the
    /// retained history of a `session/resume` calls it again, because the
    /// replay gives each update of the session again. A failed replay gives
    /// the earlier state back. A resume with no history and the close keep
    /// the state.
    ///
    /// - Parameter sessionId: The session of the new state.
    /// - Returns: The new session state.
    @MainActor func makeSessionState(for sessionId: SessionId) -> SessionState

    /// Registers the handlers of the extension for one connection.
    ///
    /// Each connect calls it one time, after ``makeConnectionState()``. The
    /// handlers are not main-actor isolated. A notification handler must
    /// return promptly, because it runs in the read loop of the connection.
    /// A request handler can wait.
    ///
    /// - Parameters:
    ///   - handlers: The handlers of the connection. Each extension registers
    ///     into the same value, in the order of
    ///     ``ConnectionModel/addExtension(_:)``.
    ///   - context: The context of the connection: its logger and the
    ///     connection state of this extension.
    nonisolated func registerHandlers(
        into handlers: inout ClientModelExtensionHandlers,
        context: ClientModelExtensionContext<Self>
    )

    /// Gets the answer of a successful `initialize` of the connection.
    ///
    /// The default does nothing.
    ///
    /// - Parameters:
    ///   - response: The `initialize` answer, as the agent sent it.
    ///   - state: The connection state of the connection that sent the
    ///     `initialize`.
    @MainActor func didInitialize(_ response: InitializeResponse, state: ConnectionState)

    /// Gets the close of the connection. It runs one time for each
    /// connection.
    ///
    /// The default does nothing.
    ///
    /// - Parameter state: The connection state of the connection that closed.
    @MainActor func didClose(state: ConnectionState)

    /// Gets one `session/update` of the session, and tells whether the
    /// extension took it.
    ///
    /// The model calls it for each update, also for each standard update,
    /// in arrival order: a buffered chunk comes after each update that
    /// arrived before it. The extensions get the update in the order of
    /// ``ConnectionModel/addExtension(_:)``, before the rules of the model.
    /// The first extension that gives `true` takes the update: a later
    /// extension does not get it, and the model does not apply it, so it
    /// adds no transcript entry. An update that no extension takes goes to
    /// the rules of the model, as with no extension: an `_` update that the
    /// model does not know becomes an ``UnknownEntry``.
    ///
    /// The default gives `false`.
    ///
    /// - Parameters:
    ///   - update: The update, as the agent sent it.
    ///   - state: The session state of the session of the update.
    /// - Returns: `true` when the extension took the update.
    @MainActor func apply(_ update: SessionUpdate, to state: SessionState) -> Bool

    /// Gets the request of a `session/new` or a `session/resume` of the
    /// session, so the extension can seed its session state.
    ///
    /// The model calls it before it folds an update that follows the
    /// request: after the agent accepted a `session/new`, and before a
    /// `session/resume` goes out. A child session gets no call, because no
    /// request of the client starts it.
    ///
    /// The default does nothing.
    ///
    /// - Parameters:
    ///   - state: The session state of the session.
    ///   - request: The request that went out, with only the MCP servers
    ///     that the agent can get.
    @MainActor func didStartSession(state: SessionState, mcpServers request: any MCPServerListRequest)
}

extension ClientModelExtension {
    /// Does nothing.
    ///
    /// - Parameters:
    ///   - response: The `initialize` answer.
    ///   - state: The connection state.
    @MainActor public func didInitialize(_ response: InitializeResponse, state: ConnectionState) {}

    /// Does nothing.
    ///
    /// - Parameter state: The connection state.
    @MainActor public func didClose(state: ConnectionState) {}

    /// Takes no update.
    ///
    /// - Parameters:
    ///   - update: The session update.
    ///   - state: The session state.
    /// - Returns: `false`.
    @MainActor public func apply(_ update: SessionUpdate, to state: SessionState) -> Bool {
        false
    }

    /// Does nothing.
    ///
    /// - Parameters:
    ///   - state: The session state.
    ///   - request: The request that started the session.
    @MainActor public func didStartSession(state: SessionState, mcpServers request: any MCPServerListRequest) {}
}

/// Finds the model of a session of one connection on the main actor.
typealias ExtensionSessionLookup = @MainActor @Sendable (SessionId) -> SessionModel?

/// What one extension gets for one connection in
/// ``ClientModelExtension/registerHandlers(into:context:)``.
///
/// The context is `Sendable`, so a handler can capture it.
public struct ClientModelExtensionContext<Extension: ClientModelExtension>: Sendable {
    /// The diagnostic sink of the connection; never stdout.
    public let connectionLogger: ACPLogger

    /// Holds the connection state on the main actor.
    private let stateHolder: MainActorHolder<Extension.ConnectionState>

    /// Finds the model of a session of this connection.
    private let sessions: ExtensionSessionLookup

    /// Makes the context of one connection.
    ///
    /// - Parameters:
    ///   - connectionLogger: The diagnostic sink of the connection.
    ///   - connectionState: The connection state of the extension.
    ///   - sessions: Finds the model of a session of the connection.
    @MainActor
    init(
        connectionLogger: ACPLogger,
        connectionState: Extension.ConnectionState,
        sessions: @escaping ExtensionSessionLookup
    ) {
        self.connectionLogger = connectionLogger
        stateHolder = MainActorHolder(connectionState)
        self.sessions = sessions
    }

    /// The connection state of the extension for this connection. A later
    /// connection does not change it.
    @MainActor public var connectionState: Extension.ConnectionState {
        stateHolder.value
    }

    /// Gives the model of a session of this connection: an open session, or
    /// a child session at any level under one.
    ///
    /// A notification handler uses it for a session notification that is not
    /// a `session/update`. The handler hops to the main actor first, for
    /// example with `await MainActor.run { context.session(for: id) }`.
    ///
    /// - Parameter sessionId: The id of the session.
    /// - Returns: The model, or `nil` when the session is not open, and
    ///   after this connection closed or a later connection replaced it.
    @MainActor public func session(for sessionId: SessionId) -> SessionModel? {
        sessions(sessionId)
    }

    /// Gives the session state of the extension for a session of this
    /// connection.
    ///
    /// - Parameter sessionId: The id of the session.
    /// - Returns: The session state, or `nil` when ``session(for:)`` gives no
    ///   model.
    @MainActor public func sessionState(for sessionId: SessionId) -> Extension.SessionState? {
        session(for: sessionId)?.extensionState(Extension.self)
    }
}

/// Holds one value on the main actor, so a `Sendable` value can carry a
/// value that is not `Sendable`.
@MainActor
final class MainActorHolder<Value> {
    /// The value.
    let value: Value

    /// Makes the holder.
    ///
    /// - Parameter value: The value to hold.
    init(_ value: Value) {
        self.value = value
    }
}

/// The extension handlers of one connection. Each
/// ``ClientModelExtension`` registers its handlers into one shared value.
///
/// The value records the name of each registered method and notification.
/// When a method or a notification is registered again, the later handler
/// replaces the earlier handler, and the value logs one diagnostic with the
/// name to the logger of the connection. A method and a notification of the
/// same name are two different registrations.
public struct ClientModelExtensionHandlers: Sendable {
    /// The text that starts each diagnostic.
    private static let logPrefix = "ClientModelExtensionHandlers: "

    /// The handlers that the connection serves.
    private(set) var handlers = ExtensionHandlers()

    /// The name of each registered method.
    private var methodNames: Set<String> = []

    /// The name of each registered notification.
    private var notificationNames: Set<String> = []

    /// The diagnostic sink of the connection.
    private let logger: ACPLogger

    /// Makes a value with no handler.
    ///
    /// - Parameter logger: The diagnostic sink of the connection.
    init(logger: ACPLogger) {
        self.logger = logger
    }

    /// Registers the handler of one extension method. A second registration
    /// for the same method replaces the first, and logs one diagnostic.
    ///
    /// - Parameters:
    ///   - method: The wire method. It must start with `_`.
    ///   - paramsType: The type that the params decode to. Use `JSONValue`
    ///     for raw params.
    ///   - handler: Serves one call, and gives the result. It runs in its own
    ///     task, so it can wait. Throw a `RequestError` to answer with that
    ///     JSON-RPC error.
    public mutating func registerMethod<Params: Decodable & SendableMetatype, Result: Encodable & SendableMetatype>(
        _ method: String,
        params paramsType: Params.Type,
        handler: @escaping @Sendable (Params) async throws -> Result
    ) {
        Self.record(method, kind: "method", in: &methodNames, logger: logger)
        handlers.registerMethod(method, params: paramsType, handler: handler)
    }

    /// Registers the handler of one extension notification. A second
    /// registration for the same notification replaces the first, and logs
    /// one diagnostic.
    ///
    /// - Parameters:
    ///   - method: The wire method. It must start with `_`.
    ///   - paramsType: The type that the params decode to. Use `JSONValue`
    ///     for raw params.
    ///   - handler: Gets the params of each notification. It runs in the read
    ///     loop of the connection, so it must return promptly.
    public mutating func registerNotification<Params: Decodable & SendableMetatype>(
        _ method: String,
        params paramsType: Params.Type,
        handler: @escaping @Sendable (Params) async -> Void
    ) {
        Self.record(method, kind: "notification", in: &notificationNames, logger: logger)
        handlers.registerNotification(method, params: paramsType, handler: handler)
    }

    /// Records one registered name, and logs one diagnostic when the name is
    /// registered again.
    ///
    /// - Parameters:
    ///   - name: The wire method.
    ///   - kind: The kind of the registration, as a word for the diagnostic.
    ///   - names: The registered names of that kind.
    ///   - logger: The diagnostic sink of the connection.
    private static func record(_ name: String, kind: String, in names: inout Set<String>, logger: ACPLogger) {
        guard !names.insert(name).inserted else { return }
        logger.log(
            logPrefix
                + "the extension \(kind) \"\(name)\" is registered again; the later handler replaces the earlier handler"
        )
    }
}
