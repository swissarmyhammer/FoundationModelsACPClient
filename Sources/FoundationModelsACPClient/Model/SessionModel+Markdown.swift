import ACPMarkdown
import FoundationModelsACP

// The Markdown document of a session (D202). The renderer of `ACPMarkdown`
// makes the text. This model gives it the merged engine entries in engine
// order, so the text of the client and the text of the agent for the same
// updates are the same.

extension SessionModel {
    /// Makes a Markdown document of the transcript of the session.
    ///
    /// The document holds the entries of ``wireEntries``: the entries that
    /// the agent also has, in engine order. A local entry that the agent did
    /// not get is not in the document: a pending or failed prompt, and a
    /// local error entry. A prompt that the agent echoed is in the document,
    /// at the position of its echo. Thus the document of a live model and
    /// the document of a replay of the same updates are the same.
    ///
    /// When `options.title` is `nil`, the title of ``sessionInfo`` is the
    /// title of the document. The document has no date, no time and no
    /// random identifier, so two calls on the same state give the same text.
    ///
    /// - Parameter options: The options of the renderer.
    /// - Returns: The Markdown document.
    public func markdown(options: SessionMarkdown.Options = .init()) -> String {
        SessionMarkdown.render(entries: wireEntries, sessionInfo: sessionInfo, options: options)
    }
}
