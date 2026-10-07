import FoundationModelsACP

/// The auth state of a connection, for a UI to observe.
///
/// ``ConnectionModel`` sets the state from the `authMethods` of the
/// `initialize` answer, and changes it on each login and logout, on each
/// terminal login, and on each `-32000` (`authentication_required`) answer of
/// the agent to a session request or a list request, or to a prompt or a
/// configuration change of a session model.
public enum AuthState: Hashable, Sendable {
    /// The connection did not initialize yet, so the auth methods of the
    /// agent are not known.
    case unknown

    /// The agent lists no auth method, so the connection needs no login.
    case notRequired

    /// The connection needs a login with one of these auth methods of the
    /// agent: no login succeeded, a logout succeeded, or the agent answered
    /// a request with `-32000`, also after a login (for example an expired
    /// login).
    case required([AuthMethod])

    /// The login with this auth method succeeded.
    case authenticated(AuthMethodId)

    /// The terminal login with this auth method succeeded, but the open
    /// connection is not authenticated. The host must connect again with a
    /// new transport and send `initialize`. When the answer of that
    /// `initialize` still lists the method, the state becomes
    /// ``authenticated(_:)``. The host then retries the operation that
    /// needed the login.
    case reconnectRequired(AuthMethodId)

    /// The last auth operation failed. The record tells the operation and
    /// the reason.
    case failed(AuthFailure)

    /// Makes the state that an `initialize` answer gives.
    ///
    /// - Parameter methods: The auth methods that the agent lists.
    init(advertising methods: [AuthMethod]) {
        self = methods.isEmpty ? .notRequired : .required(methods)
    }
}
