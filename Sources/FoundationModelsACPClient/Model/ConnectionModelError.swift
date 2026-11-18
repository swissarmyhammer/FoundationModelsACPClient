import FoundationModelsACP

/// An error that ``ConnectionModel`` throws for an operation that it refuses
/// or that failed outside the ACP wire.
public enum ConnectionModelError: Error, Hashable, Sendable {
    /// The agent does not advertise the capability of the ACP method, so the
    /// model sent no request.
    ///
    /// - Parameter method: The ACP wire method, for example `auth/logout`, or
    ///   ``terminalAuthOperation`` for a terminal login, which has no wire
    ///   method.
    case unsupported(method: String)

    /// The session is not in ``ConnectionModel/openSessions``, or its model
    /// does not know the working directory of the session yet because its
    /// first resume still runs. Thus the model cannot make a request that
    /// needs the workspace of the session, and sent no request.
    ///
    /// - Parameter sessionId: The id of the session.
    case sessionNotOpen(sessionId: SessionId)

    /// The terminal auth process did not exit with status zero.
    ///
    /// - Parameter exitStatus: The exit status of the process, or `nil` when
    ///   the process ended with no exit status.
    case terminalAuthFailed(exitStatus: Int32?)

    /// The name of the terminal login in ``unsupported(method:)``. A terminal
    /// login sends no ACP request, so it has no wire method.
    public static let terminalAuthOperation = "terminal auth"
}
