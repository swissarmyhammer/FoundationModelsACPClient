import FoundationModelsACP

/// The source of the transcript of a session model.
///
/// The client sets this value itself; no response field gives it. It comes
/// from the `replayFrom` cursor of the `session/resume` request that the
/// client sent, after the replay succeeded.
public enum SessionHistory: Hashable, Sendable {
    /// The transcript holds only the updates that arrived while the model was
    /// attached. This is the state of a new session, and of a resumed session
    /// that asked for no replay.
    case live

    /// The agent replayed its retained history from the cursor, before the
    /// live updates. With `replayFrom == .start`, the transcript holds all of
    /// the history that the agent keeps.
    case retained(replayFrom: ReplayFrom)
}
