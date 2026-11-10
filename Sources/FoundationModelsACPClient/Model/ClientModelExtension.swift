import FoundationModelsACP

/// An extension of the client models: it serves the `_` extension methods
/// and notifications of the agent, and keeps its own state for each
/// connection.
///
/// A host adds an extension with ``ConnectionModel/addExtension(_:)``
/// before ``ConnectionModel/connect(over:logger:bufferLimits:client:)``.
/// Each connect makes a new connection state for each extension with
/// ``makeConnectionState()``, and then asks each extension to register its
/// handlers with ``registerHandlers(into:context:)``. The host reads the
/// state of the current connection with
/// ``ConnectionModel/extensionState(_:)``.
///
/// The protocol has two isolation parts:
///
/// - The handlers run in the connection, not on the main actor. A
///   notification handler runs in the read loop of the connection, in
///   arrival order, so it must return promptly. A request handler runs in its
///   own task, so it can wait.
/// - The connection state and the hooks ``didInitialize(_:state:)`` and
///   ``didClose(state:)`` are on the main actor. A handler that changes
///   main-actor state hops to the main actor, for example with
///   `await MainActor.run { context.connectionState.count += 1 }`.
///
/// The protocol itself is not main-actor isolated. Thus a conforming type
/// writes `@MainActor` on its ``makeConnectionState()``,
/// ``didInitialize(_:state:)`` and ``didClose(state:)``.
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
}

/// What one extension gets for one connection in
/// ``ClientModelExtension/registerHandlers(into:context:)``.
///
/// The context is `Sendable`, so a handler can capture it.
public struct ClientModelExtensionContext<Extension: ClientModelExtension>: Sendable {
    /// The diagnostic sink of the connection; never stdout.
    public let connectionLogger: ACPLogger

    /// Holds the connection state on the main actor.
    private let stateHolder: MainActorHolder<Extension.ConnectionState>

    /// Makes the context of one connection.
    ///
    /// - Parameters:
    ///   - connectionLogger: The diagnostic sink of the connection.
    ///   - connectionState: The connection state of the extension.
    @MainActor
    init(connectionLogger: ACPLogger, connectionState: Extension.ConnectionState) {
        self.connectionLogger = connectionLogger
        stateHolder = MainActorHolder(connectionState)
    }

    /// The connection state of the extension for this connection. A later
    /// connection does not change it.
    @MainActor public var connectionState: Extension.ConnectionState {
        stateHolder.value
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
