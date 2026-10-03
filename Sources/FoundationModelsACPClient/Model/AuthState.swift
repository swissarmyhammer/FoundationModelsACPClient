import FoundationModelsACP

/// The auth state of a connection, for a UI to observe.
///
/// ``ConnectionModel`` sets the state from the `authMethods` of the
/// `initialize` answer, and changes it on each login and logout.
public enum AuthState: Hashable, Sendable {
    /// The connection did not initialize yet, so the auth methods of the
    /// agent are not known.
    case unknown

    /// The agent lists no auth method, so the connection needs no login.
    case notRequired

    /// The agent lists these auth methods, and no login succeeded.
    case required([AuthMethod])

    /// The login with this auth method succeeded.
    case authenticated(AuthMethodId)

    /// The agent refused the last login with this error.
    case failed(RequestError)

    /// Makes the state that an `initialize` answer gives.
    ///
    /// - Parameter methods: The auth methods that the agent lists.
    init(advertising methods: [AuthMethod]) {
        self = methods.isEmpty ? .notRequired : .required(methods)
    }
}
