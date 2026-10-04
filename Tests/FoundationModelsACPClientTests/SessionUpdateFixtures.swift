import Foundation
import FoundationModelsACP

@testable import FoundationModelsACPClient

// This file holds the shared builders for the session-update tests. Each
// builder makes one small wire value, so the tests stay short and easy to
// read.

/// The session id that most tests use.
let testSession = SessionId(rawValue: "session-1")

/// The id of a second session, for the tests that need two sessions.
let otherTestSession = SessionId(rawValue: "session-2")

/// The `session/prompt` answer that the stub agents give.
///
/// Since ACP schema v2.0.0-alpha.7 a prompt response must name the user
/// message that the prompt inserted into the conversation, so each stub agent
/// answers with this one id.
let testPromptResponse = PromptResponse(messageId: MessageId(rawValue: "prompted-user-1"))

/// Makes a text content block.
///
/// - Parameter text: The text of the block.
/// - Returns: The content block.
func textBlock(_ text: String) -> ContentBlock {
    .text(TextContent(text: text))
}

/// Makes a user-message-chunk update.
///
/// - Parameters:
///   - text: The text of the chunk.
///   - message: The raw message id.
/// - Returns: The update.
func userChunk(text: String, message: String = "user-1") -> SessionUpdate {
    .userMessageChunk(ContentChunk(content: textBlock(text), messageId: MessageId(rawValue: message)))
}

/// Makes an agent-message-chunk update.
///
/// - Parameters:
///   - text: The text of the chunk.
///   - message: The raw message id.
/// - Returns: The update.
func agentChunk(text: String, message: String = "agent-1") -> SessionUpdate {
    .agentMessageChunk(ContentChunk(content: textBlock(text), messageId: MessageId(rawValue: message)))
}

/// Makes an agent-thought-chunk update.
///
/// - Parameters:
///   - text: The text of the chunk.
///   - message: The raw message id.
/// - Returns: The update.
func thoughtChunk(text: String, message: String = "thought-1") -> SessionUpdate {
    .agentThoughtChunk(ContentChunk(content: textBlock(text), messageId: MessageId(rawValue: message)))
}

/// Makes an idle state update.
///
/// - Parameter stopReason: The stop reason, or `nil` to omit it.
/// - Returns: The update.
func idleState(stopReason: StopReason?) -> SessionUpdate {
    .stateUpdate(.idle(IdleStateUpdate(stopReason: stopReason)))
}

/// Makes a tool-call update that carries only a status.
///
/// - Parameters:
///   - id: The raw tool-call id.
///   - status: The status to carry.
/// - Returns: The update.
func toolCallStatus(id: String, _ status: ToolCallStatus) -> SessionUpdate {
    .toolCallUpdate(ToolCallUpdate(toolCallId: ToolCallId(rawValue: id), status: .value(status)))
}
