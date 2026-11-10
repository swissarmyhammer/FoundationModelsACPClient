import FoundationModelsACP

/// Makes the session state of one extension for one session.
typealias SessionExtensionFactory = @MainActor (SessionId) -> OpenedSessionExtension

/// One ``ClientModelExtension`` with its session state for one session
/// model, with the type erased.
@MainActor
struct OpenedSessionExtension {
    /// The key of the extension: the metatype of its type.
    let key: ObjectIdentifier

    /// The session state of the extension.
    let state: AnyObject

    /// Gives one session update to the extension, and tells whether the
    /// extension took it.
    let apply: (SessionUpdate) -> Bool

    /// Gives the request that started the session to the extension.
    let didStartSession: (any MCPServerListRequest) -> Void

    /// Makes a new session state for an extension.
    ///
    /// - Parameters:
    ///   - clientExtension: The extension.
    ///   - sessionId: The session of the state.
    init<Extension: ClientModelExtension>(_ clientExtension: Extension, sessionId: SessionId) {
        let state = clientExtension.makeSessionState(for: sessionId)
        key = ObjectIdentifier(Extension.self)
        self.state = state
        apply = { clientExtension.apply($0, to: state) }
        didStartSession = { clientExtension.didStartSession(state: state, mcpServers: $0) }
    }

    /// Gives the factory that makes the session state of an extension.
    ///
    /// - Parameter clientExtension: The extension.
    /// - Returns: The factory.
    static func factory(for clientExtension: some ClientModelExtension) -> SessionExtensionFactory {
        { OpenedSessionExtension(clientExtension, sessionId: $0) }
    }
}

/// The extensions of one session model, in the order of
/// ``ConnectionModel/addExtension(_:)``, each with its session state.
///
/// The value is a value type, so a replay rollback keeps the earlier states
/// as they are, and gives them back.
@MainActor
struct SessionExtensions {
    /// The session of the states.
    private let sessionId: SessionId

    /// Makes the session state of each extension, in order.
    private let factories: [SessionExtensionFactory]

    /// The extensions with their session states, in order.
    private let members: [OpenedSessionExtension]

    /// The session state of each extension, by the key of the extension.
    private let states: [ObjectIdentifier: AnyObject]

    /// Makes a new session state for each extension.
    ///
    /// - Parameters:
    ///   - factories: Makes the session state of each extension, in order.
    ///   - sessionId: The session of the states.
    init(_ factories: [SessionExtensionFactory], for sessionId: SessionId) {
        let members = factories.map { $0(sessionId) }
        self.sessionId = sessionId
        self.factories = factories
        self.members = members
        states = Dictionary(members.map { ($0.key, $0.state) }) { _, later in later }
    }

    /// Gives the same extensions, each with a new session state.
    ///
    /// - Returns: The extensions with new states.
    func remade() -> SessionExtensions {
        SessionExtensions(factories, for: sessionId)
    }

    /// Gives the session state of one extension type.
    ///
    /// This is the one place that casts a session state to its type.
    ///
    /// - Parameter extensionType: The type of the extension.
    /// - Returns: The session state, or `nil` when the session has no
    ///   extension of that type.
    func state<Extension: ClientModelExtension>(of extensionType: Extension.Type) -> Extension.SessionState? {
        states[ObjectIdentifier(extensionType)] as? Extension.SessionState
    }

    /// Gives one session update to the extensions, in order, until one takes
    /// it.
    ///
    /// - Parameter update: The update.
    /// - Returns: `true` when an extension took the update. A later
    ///   extension then did not get it.
    func take(_ update: SessionUpdate) -> Bool {
        // `contains(where:)` stops at the first extension that takes the
        // update, so a later extension does not see it.
        members.contains { $0.apply(update) }
    }

    /// Gives the request that started the session to each extension, in
    /// order.
    ///
    /// - Parameter request: The request that went out.
    func didStartSession(_ request: some MCPServerListRequest) {
        for member in members {
            member.didStartSession(request)
        }
    }
}
