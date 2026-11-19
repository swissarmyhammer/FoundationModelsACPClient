import ACPMarkdown
import FoundationModelsACP

// The share snapshot of a session (D208). `SessionSnapshot` of `ACPMarkdown`
// applies the content rules of the share and makes the Markdown. This model
// gives it the merged engine entries in engine order: the same entries as
// `markdown(options:)`. Thus the snapshot of the client and the snapshot of
// the agent for the same updates are the same.

extension SessionModel {
    /// Makes the share snapshot of the session.
    ///
    /// The snapshot holds the entries of ``wireEntries``: the entries that
    /// the agent also has, in engine order. These are the entries of
    /// ``markdown(options:)``. A local entry that the agent did not get is
    /// not in the snapshot: a pending or failed prompt, and a local error
    /// entry. Thus the snapshot of a live model and the snapshot of a replay
    /// of the same updates are the same.
    ///
    /// When `options.title` is `nil`, the title of ``sessionInfo`` is the
    /// title of the snapshot. The entries hold no session information, so
    /// this model sets the title before it builds the snapshot.
    ///
    /// - Parameter options: The options of the share.
    /// - Returns: The snapshot.
    public func snapshot(options: SessionSnapshot.Options) -> SessionSnapshot {
        var resolved = options
        resolved.title = options.title ?? sessionInfo.title.currentValue
        return SessionSnapshot.build(updates: wireTranscriptUpdates, options: resolved)
    }
}
