/// An error that ``SessionModel`` throws for an operation that it refuses
/// because of the kind of the model.
public enum SessionModelError: Error, Hashable, Sendable {
    /// The model is read-only (``SessionModel/isReadOnly``), so it sent
    /// nothing to the agent. A read-only model shows a share snapshot. It has
    /// no connection and no agent.
    case readOnly

    /// The model is not read-only, so it refuses an operation that only a
    /// read-only model allows, for example
    /// ``SessionModel/replace(with:)``. The model did not change.
    case notReadOnly
}
