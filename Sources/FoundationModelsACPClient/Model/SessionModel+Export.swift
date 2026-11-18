import Foundation
import FoundationModelsExtras

// The default file name and the default folder of a Markdown export of a
// session (D202). A host gives them to its save panel. The file name is the
// D199 slug of the session, so the name of the file and the `@<slug>` of the
// session agree.

extension SessionModel {
    /// The number of characters of the short id of a session.
    ///
    /// This value must stay equal to the length of `SessionSummary.shortID`
    /// of FoundationModelsExtras.
    private static let shortIDLength = 7

    /// The extension of the file of a Markdown export.
    private static let markdownFileExtension = "md"

    /// The default file name of a Markdown export of the session.
    ///
    /// The name is the slug of the title of ``sessionInfo``, then `.md`.
    /// `SessionSlug.make(from:)` of FoundationModelsExtras makes the slug, so
    /// the name is the D199 slug of the session. When the session has no
    /// title, or the slug of the title is empty, the name is the short id of
    /// the session, then `.md`.
    ///
    /// The short id is the last seven characters of the text of
    /// ``sessionId``, in lower case. This rule must stay equal to the rule of
    /// `SessionSummary.shortID` of FoundationModelsExtras.
    public var exportFileName: String {
        let titleSlug = SessionSlug.make(from: sessionInfo.title.currentValue ?? "")
        let baseName = titleSlug.isEmpty ? shortID : titleSlug
        return "\(baseName).\(Self.markdownFileExtension)"
    }

    /// The default folder of a Markdown export of the session: the file URL
    /// of ``cwd``. `nil` when the model has no ``cwd``.
    public var exportFolder: URL? {
        cwd.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
    }

    /// The short id of the session: the last seven characters of the text of
    /// ``sessionId``, in lower case. It must stay equal to
    /// `SessionSummary.shortID` of FoundationModelsExtras.
    private var shortID: String {
        String(sessionId.rawValue.suffix(Self.shortIDLength)).lowercased()
    }
}
