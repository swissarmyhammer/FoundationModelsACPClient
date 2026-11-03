import Foundation
import FoundationModelsACP
import Observation

/// **UNSTABLE**
///
/// A message between this session and another session of the same agent, as
/// an observable transcript entry.
///
/// A `session_message` update sets the participants and can set the content.
/// A `session_message_chunk` update appends one content block. The entry only
/// folds these wire updates: it holds no link to the other session.
@MainActor @Observable
public final class SessionMessageEntry: ObservableTranscriptEntry {
    /// The stable identity of the entry.
    public nonisolated let id: TranscriptEntry.ID

    /// The start time and the end time of the message. The message ends when
    /// the next entry starts, or when the agent becomes idle. See
    /// ``EntryTiming``.
    public let timing = EntryTiming()

    /// The identifier of the message in the transcript of this session.
    public let messageId: MessageId

    /// The content of the message.
    public internal(set) var content: [ContentBlock] = []

    /// The session that sent the message, or `nil` when the agent gave none.
    public internal(set) var senderSessionId: SessionId?

    /// The session that receives the message, or `nil` when the agent gave
    /// none.
    public internal(set) var recipientSessionId: SessionId?

    /// On an incoming view, the `messageId` of the same message in the
    /// transcript of the sender.
    public internal(set) var senderMessageId: MessageId?

    /// On an outgoing view, the `messageId` of the same message in the
    /// transcript of the recipient.
    public internal(set) var recipientMessageId: MessageId?

    /// The `_meta` field of the message.
    public internal(set) var meta: JSONValue?

    /// Makes the entry for an inter-session message from the wire.
    ///
    /// - Parameters:
    ///   - entry: The engine entry of the message.
    ///   - message: The merged message that the entry holds.
    init(wire entry: FoundationModelsACP.SessionEntry, message: FoundationModelsACP.SessionEntry.InterSessionMessage) {
        self.id = .wire(entry.id)
        self.messageId = message.messageId
        copy(message)
    }

    /// Copies the merged state of the engine entry, and writes only the
    /// fields that changed. The identity and the message id do not change.
    ///
    /// - Parameter entry: The engine entry of this message.
    func update(from entry: FoundationModelsACP.SessionEntry) {
        guard case .sessionMessage(let message) = entry.kind else {
            recordKindMismatch()
            return
        }
        copy(message)
    }

    /// Writes each changed field of a merged message.
    ///
    /// - Parameter message: The merged message.
    private func copy(_ message: FoundationModelsACP.SessionEntry.InterSessionMessage) {
        assign(message.content, to: \.content)
        assign(message.senderSessionId.currentValue, to: \.senderSessionId)
        assign(message.recipientSessionId.currentValue, to: \.recipientSessionId)
        assign(message.senderMessageId.currentValue, to: \.senderMessageId)
        assign(message.recipientMessageId.currentValue, to: \.recipientMessageId)
        assign(message.meta.currentValue, to: \.meta)
    }
}
