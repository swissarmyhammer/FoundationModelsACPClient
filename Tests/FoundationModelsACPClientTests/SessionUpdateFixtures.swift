import Foundation
import FoundationModelsACP

@testable import FoundationModelsACPClient

// This file holds the shared builders for the session-update tests. Each
// builder makes one small wire value, so the tests stay short and easy to
// read.

/// The session id that most tests use.
let testSession = SessionId(rawValue: "session-1")

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
func userChunk(_ text: String, message: String = "user-1") -> SessionUpdate {
    .userMessageChunk(ContentChunk(content: textBlock(text), messageId: MessageId(rawValue: message)))
}

/// Makes an agent-message-chunk update.
///
/// - Parameters:
///   - text: The text of the chunk.
///   - message: The raw message id.
/// - Returns: The update.
func agentChunk(_ text: String, message: String = "agent-1") -> SessionUpdate {
    .agentMessageChunk(ContentChunk(content: textBlock(text), messageId: MessageId(rawValue: message)))
}

/// Makes an agent-thought-chunk update.
///
/// - Parameters:
///   - text: The text of the chunk.
///   - message: The raw message id.
/// - Returns: The update.
func thoughtChunk(_ text: String, message: String = "thought-1") -> SessionUpdate {
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
func toolCallStatus(_ id: String, _ status: ToolCallStatus) -> SessionUpdate {
    .toolCallUpdate(ToolCallUpdate(toolCallId: ToolCallId(rawValue: id), status: .value(status)))
}

/// Applies each update to the client for the test session.
///
/// - Parameters:
///   - client: The client under test.
///   - updates: The updates to apply, in order.
@MainActor
func drive(_ client: SwiftUIACPClient, _ updates: SessionUpdate...) async {
    for update in updates {
        await client.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
    }
}
