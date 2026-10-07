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
    ///
    /// A request that went out and failed gives ``request(_:)``. A terminal
    /// auth process that failed gives ``terminal(exitStatus:message:)``. An
    /// operation that the model did not start, because the agent does not
    /// advertise it, gives ``unsupported(method:)``. ``message`` gives a text
    /// that a UI can show for each reason.
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

        /// The agent does not advertise the operation, so the model sent
        /// nothing and ran no process. The operation also threw
        /// ``ConnectionModelError/unsupported(method:)`` with the same
        /// `method`.
        ///
        /// - Parameter method: The ACP wire method of the operation, or
        ///   ``ConnectionModelError/terminalAuthOperation`` for a terminal
        ///   login.
        case unsupported(method: String)

        /// A text about the failure that a UI can show.
        ///
        /// - ``request(_:)``: the message of the JSON-RPC error.
        /// - ``terminal(exitStatus:message:)``: the message of the failure
        ///   when there is one. If not, a text that gives the exit status, or
        ///   that says that the process did not stop normally.
        /// - ``unsupported(method:)``: a text that says that the agent cannot
        ///   do this auth operation.
        public var message: String {
            switch self {
            case .request(let error):
                error.message
            case .terminal(let exitStatus, let message):
                message ?? Self.terminalMessage(exitStatus: exitStatus)
            case .unsupported:
                "The agent cannot do this authentication operation."
            }
        }

        /// Gives the text of a failed terminal auth process that gave no
        /// message.
        ///
        /// - Parameter exitStatus: The exit status of the process, or `nil`
        ///   when the process did not exit normally.
        /// - Returns: A text that gives the exit status, or that says that
        ///   the process did not stop normally.
        private static func terminalMessage(exitStatus: Int32?) -> String {
            guard let exitStatus else {
                return "The sign-in process did not stop normally."
            }
            return "The sign-in process stopped with exit status \(exitStatus)."
        }
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
