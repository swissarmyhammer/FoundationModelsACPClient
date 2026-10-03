import Foundation
import FoundationModelsACP
import Observation

/// A message from the user, as an observable transcript entry.
///
/// A user message from the wire has the engine identity and is ``SendState/sent``.
/// A local user message is the prompt that the client sends: it starts
/// ``SendState/pending`` with no ``messageId``. When the agent links it, the
/// client sets ``messageId`` and ``sendState``. The ``id`` stays the same, so
/// the row keeps its place and its state.
@MainActor @Observable
public final class UserMessageEntry: MessageTranscriptEntry {
    /// The stable identity of the entry.
    public nonisolated let id: TranscriptEntry.ID

    /// The content of the message.
    public internal(set) var content: [ContentBlock]

    /// The identifier of the message, or `nil` for a local message that the
    /// agent did not link yet.
    public internal(set) var messageId: MessageId?

    /// The send state of the message.
    public internal(set) var sendState: SendState

    /// The `_meta` field of the message.
    public internal(set) var meta: JSONValue?

    /// Makes a local user message for a prompt that the client sends.
    ///
    /// - Parameters:
    ///   - content: The content of the prompt.
    ///   - meta: The `_meta` field of the prompt, or `nil`.
    init(content: [ContentBlock], meta: JSONValue?) {
        self.id = .local(UUID())
        self.content = content
        self.messageId = nil
        self.sendState = .pending
        self.meta = meta
    }

    /// Makes the entry for a user message from the wire.
    ///
    /// - Parameter entry: The engine entry of the message.
    init(wire entry: FoundationModelsACP.SessionEntry) {
        self.id = .wire(entry.id)
        self.content = []
        self.messageId = nil
        self.sendState = .sent
        self.meta = nil
        update(from: entry)
    }

    /// Copies the merged state of the engine entry, and writes only the
    /// fields that changed. The identity and the send state do not change.
    ///
    /// - Parameter entry: The engine entry of this message.
    func update(from entry: FoundationModelsACP.SessionEntry) {
        guard case .userMessage(let message) = entry.kind else {
            recordKindMismatch()
            return
        }
        apply(message)
    }
}
