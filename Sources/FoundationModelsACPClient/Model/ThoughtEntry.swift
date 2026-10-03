import Foundation
import FoundationModelsACP
import Observation

/// A thought (reasoning) from the agent, as an observable transcript entry.
///
/// A thought and an agent message with the same `messageId` are two entries,
/// so a UI can show, collapse, or hide the reasoning on its own.
@MainActor @Observable
public final class ThoughtEntry: MessageTranscriptEntry {
    /// The stable identity of the entry.
    public nonisolated let id: TranscriptEntry.ID

    /// The content of the thought.
    public internal(set) var content: [ContentBlock] = []

    /// The identifier of the thought message.
    public internal(set) var messageId: MessageId?

    /// The `_meta` field of the thought.
    public internal(set) var meta: JSONValue?

    /// Makes the entry for an agent thought from the wire.
    ///
    /// - Parameter entry: The engine entry of the thought.
    init(wire entry: FoundationModelsACP.SessionEntry) {
        self.id = .wire(entry.id)
        update(from: entry)
    }

    /// Copies the merged state of the engine entry, and writes only the
    /// fields that changed.
    ///
    /// - Parameter entry: The engine entry of this thought.
    func update(from entry: FoundationModelsACP.SessionEntry) {
        guard case .agentThought(let message) = entry.kind else {
            recordKindMismatch()
            return
        }
        apply(message)
    }
}
