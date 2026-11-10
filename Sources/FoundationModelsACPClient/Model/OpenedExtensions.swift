import FoundationModelsACP

/// Registers the handlers of one extension for one connection.
typealias ExtensionRegistration = @Sendable (inout ClientModelExtensionHandlers) -> Void

/// One ``ClientModelExtension`` with its connection state for one
/// connection, with the type erased.
@MainActor
struct OpenedExtension {
    /// The key of the extension: the metatype of its type.
    let key: ObjectIdentifier

    /// The connection state of the extension.
    let state: AnyObject

    /// Registers the handlers of the extension, with the context of this
    /// connection.
    let registration: ExtensionRegistration

    /// Gives an `initialize` answer to the extension.
    let didInitialize: (InitializeResponse) -> Void

    /// Gives the close of the connection to the extension.
    let didClose: () -> Void

    /// Makes a new connection state for an extension, and the context of the
    /// connection.
    ///
    /// - Parameters:
    ///   - clientExtension: The extension.
    ///   - connectionLogger: The diagnostic sink of the connection.
    init<Extension: ClientModelExtension>(_ clientExtension: Extension, connectionLogger: ACPLogger) {
        let state = clientExtension.makeConnectionState()
        let context = ClientModelExtensionContext<Extension>(
            connectionLogger: connectionLogger,
            connectionState: state
        )
        key = ObjectIdentifier(Extension.self)
        self.state = state
        registration = { clientExtension.registerHandlers(into: &$0, context: context) }
        didInitialize = { clientExtension.didInitialize($0, state: state) }
        didClose = { clientExtension.didClose(state: state) }
    }
}

/// The extensions of one connection, in the order of
/// ``ConnectionModel/addExtension(_:)``, each with its connection state.
///
/// ``didClose()`` gives the close to each extension one time only, also when
/// two paths record the close of the connection.
@MainActor
final class OpenedExtensions {
    /// The extensions, in order.
    private let members: [OpenedExtension]

    /// The connection state of each extension, by the key of the extension.
    private let states: [ObjectIdentifier: AnyObject]

    /// Whether ``didClose()`` ran.
    private var isClosed = false

    /// Makes a new connection state for each extension.
    ///
    /// - Parameters:
    ///   - extensions: The extensions, in order.
    ///   - connectionLogger: The diagnostic sink of the connection.
    init(_ extensions: [any ClientModelExtension], connectionLogger: ACPLogger) {
        let members = extensions.map { OpenedExtension($0, connectionLogger: connectionLogger) }
        self.members = members
        states = Dictionary(members.map { ($0.key, $0.state) }) { _, later in later }
    }

    /// The handler registration of each extension, in order.
    var registrations: [ExtensionRegistration] {
        members.map(\.registration)
    }

    /// Gives the connection state of one extension type.
    ///
    /// This is the one place that casts a connection state to its type.
    ///
    /// - Parameter extensionType: The type of the extension.
    /// - Returns: The connection state, or `nil` when no extension of that
    ///   type is in the connection.
    func state<Extension: ClientModelExtension>(of extensionType: Extension.Type) -> Extension.ConnectionState? {
        states[ObjectIdentifier(extensionType)] as? Extension.ConnectionState
    }

    /// Gives an `initialize` answer to each extension, in order.
    ///
    /// - Parameter response: The answer, as the agent sent it.
    func didInitialize(_ response: InitializeResponse) {
        for member in members {
            member.didInitialize(response)
        }
    }

    /// Gives the close of the connection to each extension, in order. A
    /// second call does nothing.
    func didClose() {
        guard !isClosed else { return }
        isClosed = true
        for member in members {
            member.didClose()
        }
    }
}
