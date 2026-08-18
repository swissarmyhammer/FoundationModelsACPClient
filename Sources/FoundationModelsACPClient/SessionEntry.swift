import FoundationModelsACP

/// One item in a session's ordered entry list.
///
/// An entry carries only a stable identity and a kind. The content for an
/// entry lives in ``ACPSessionState``, keyed by the same identity, so an
/// update mutates the content in place and never touches the entry. A
/// SwiftUI `ForEach` can therefore key on ``id`` without churn.
///
/// The identities are the wire's own: a message entry carries the ACP
/// `messageId`, and a tool-call entry carries the ACP `toolCallId`. Upstream,
/// that tool-call id is Apple's own `Transcript.ToolCall.id`, so two
/// concurrent same-name tool calls stay distinguishable.
public enum SessionEntry: Identifiable, Hashable, Sendable {
    /// A message from the user.
    case userMessage(MessageId)

    /// A message from the agent.
    case agentMessage(MessageId)

    /// The agent's internal reasoning. It stays separate from
    /// ``agentMessage`` so a UI can show, collapse, or hide reasoning
    /// independently.
    case agentThought(MessageId)

    /// A tool call, keyed by its `toolCallId`.
    case toolCall(ToolCallId)

    /// The stable identity of one entry.
    public enum ID: Hashable, Sendable {
        /// The identity of a message entry.
        case message(MessageId)

        /// The identity of a tool-call entry.
        case toolCall(ToolCallId)
    }

    /// The stable identity of this entry.
    public var id: ID {
        switch self {
        case .userMessage(let messageID), .agentMessage(let messageID), .agentThought(let messageID):
            .message(messageID)
        case .toolCall(let toolCallID):
            .toolCall(toolCallID)
        }
    }
}
