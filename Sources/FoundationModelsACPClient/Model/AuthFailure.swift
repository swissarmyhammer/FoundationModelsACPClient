import FoundationModelsACP

/// The record of an auth operation that failed, for a UI to observe.
///
/// ``ConnectionModel`` keeps this value in ``AuthState/failed(_:)``. The
/// value tells which operation failed and why, so a UI can show "sign-in
/// failed" and "sign-out failed" differently.
public struct AuthFailure: Hashable, Sendable {
    /// The auth operation that failed.
    public enum Operation: Hashable, Sendable {
        /// An `auth/login` with this auth method.
        case login(AuthMethodId)

        /// An `auth/logout`.
        case logout

        /// A run of this `terminal` auth method as a separate process.
        case terminalLogin(AuthMethodId)
    }

    /// The reason that the operation failed.
    public enum Reason: Hashable, Sendable {
        /// The request failed with this JSON-RPC error. A refusal of the
        /// agent, a closed connection, a time-out, and a cancel each have
        /// one JSON-RPC form.
        case request(RequestError)

        /// The terminal auth process failed.
        ///
        /// - Parameters:
        ///   - exitStatus: The exit status of the process, or `nil` when the
        ///     process did not exit normally.
        ///   - message: A message about the failure, or `nil` when there is
        ///     none.
        case terminal(exitStatus: Int32?, message: String?)
    }

    /// The auth operation that failed.
    public let operation: Operation

    /// The reason that the operation failed.
    public let reason: Reason

    /// Makes a failure record.
    ///
    /// - Parameters:
    ///   - operation: The auth operation that failed.
    ///   - reason: The reason that the operation failed.
    public init(operation: Operation, reason: Reason) {
        self.operation = operation
        self.reason = reason
    }
}
