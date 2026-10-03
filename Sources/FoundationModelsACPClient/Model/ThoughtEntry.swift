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

    /// Gives the message of an agent-thought kind.
    ///
    /// - Parameter kind: The kind of an engine entry.
    /// - Returns: The merged thought, or `nil` for another kind.
    static func message(in kind: FoundationModelsACP.SessionEntry.Kind) -> FoundationModelsACP.SessionEntry.Message? {
        if case .agentThought(let message) = kind { message } else { nil }
    }
}
