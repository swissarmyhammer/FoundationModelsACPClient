import Foundation
import FoundationModelsACP
import Observation

/// An error that the client shows in the transcript, as an observable
/// transcript entry.
///
/// The client makes this entry itself, for example when a request fails, so
/// the entry is always ``EntryOrigin/local``. The engine has no error kind,
/// so this entry has no `update(from:)`, and its fields never change.
@MainActor @Observable
public final class ErrorEntry: ObservableTranscriptEntry {
    /// The stable identity of the entry.
    public nonisolated let id: TranscriptEntry.ID

    /// The JSON-RPC error code.
    public let code: ErrorCode

    /// The error message.
    public let message: String

    /// The JSON-RPC error data, or `nil` when the error has none.
    public let data: JSONValue?

    /// The `_meta` field of the entry. A local error has no `_meta`, so this
    /// is always `nil`.
    public var meta: JSONValue? {
        nil
    }

    /// Makes a local error entry.
    ///
    /// - Parameters:
    ///   - code: The JSON-RPC error code.
    ///   - message: The error message.
    ///   - data: The JSON-RPC error data, or `nil`.
    init(code: ErrorCode, message: String, data: JSONValue?) {
        self.id = .local(UUID())
        self.code = code
        self.message = message
        self.data = data
    }
}
