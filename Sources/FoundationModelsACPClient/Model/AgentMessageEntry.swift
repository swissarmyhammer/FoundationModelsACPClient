import Foundation
import FoundationModelsACP
import Observation

/// A message from the agent, as an observable transcript entry.
///
/// Each streamed chunk of the message changes only this object.
@MainActor @Observable
public final class AgentMessageEntry: MessageTranscriptEntry {
    /// The stable identity of the entry.
    public nonisolated let id: TranscriptEntry.ID

    /// The content of the message.
    public internal(set) var content: [ContentBlock] = []

    /// The identifier of the message.
    public internal(set) var messageId: MessageId?

    /// The `_meta` field of the message.
    public internal(set) var meta: JSONValue?

    /// Makes the entry for an agent message from the wire.
    ///
    /// - Parameter entry: The engine entry of the message.
    init(wire entry: FoundationModelsACP.SessionEntry) {
        self.id = .wire(entry.id)
        update(from: entry)
    }

    /// Gives the message of an agent-message kind.
    ///
    /// - Parameter kind: The kind of an engine entry.
    /// - Returns: The merged message, or `nil` for another kind.
    static func message(in kind: FoundationModelsACP.SessionEntry.Kind) -> FoundationModelsACP.SessionEntry.Message? {
        if case .agentMessage(let message) = kind { message } else { nil }
    }
}
