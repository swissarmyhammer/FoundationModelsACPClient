/// An error that ``ConnectionModel`` throws before it sends a request.
public enum ConnectionModelError: Error, Hashable, Sendable {
    /// The agent does not advertise the capability of the ACP method, so the
    /// model sent no request.
    ///
    /// - Parameter method: The ACP wire method, for example `auth/logout`.
    case unsupported(method: String)
}
