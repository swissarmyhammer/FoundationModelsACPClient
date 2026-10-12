import Foundation
import FoundationModelsACP

/// One transcript entry of a preview ``SessionModel``, as a simple value.
///
/// ``SessionModel/preview(sessionId:cwd:transcript:availableCommands:configOptions:mcpServers:pendingPermissions:requestSender:)``
/// makes each item into the session update that an agent sends for it, and
/// gives that update to the merge engine that a live model uses. Thus a
/// preview shows the real state of each entry. An ``error(code:message:)``
/// item is the one exception: the client makes an error entry itself, so the
/// item goes in as a live model adds a local error.
///
/// Each item gets its own message id, tool-call id, plan id, or terminal id,
/// from its position in the list. Thus two ``agent(_:)`` items in a row are
/// two messages, and not one message with two chunks.
public enum PreviewTranscriptItem: Hashable, Sendable {
    /// A user message with one text block. The message is
    /// ``SendState/sent``, as a user message from the agent always is.
    case user(String)

    /// An agent message with one text block.
    case agent(String)

    /// An agent thought with one text block.
    case thought(String)

    /// A tool call.
    ///
    /// - Parameters:
    ///   - title: The title that tells what the tool does.
    ///   - kind: The kind of the tool.
    ///   - status: The status of the call.
    case toolCall(title: String, kind: ToolKind, status: ToolCallStatus)

    /// A plan with these entries.
    case plan([PlanEntry])

    /// An agent-owned terminal.
    ///
    /// - Parameters:
    ///   - command: The command that the terminal runs.
    ///   - output: The output text of the terminal.
    ///   - exitCode: The exit code, or `nil` while the command runs.
    case terminal(command: String, output: String, exitCode: Int?)

    /// An error that the client shows in the transcript, with no data.
    ///
    /// - Parameters:
    ///   - code: The JSON-RPC error code.
    ///   - message: The error message.
    case error(code: ErrorCode, message: String)

    /// A session update as the agent sends it, for an entry that no other
    /// case makes, for example a compaction or an update of a type that
    /// this schema revision does not know. The update can also change a
    /// last-value property, for example ``SessionModel/usage``.
    case update(SessionUpdate)

    /// Where the entry of an item comes from in a live model.
    private enum Source {
        /// The agent sends this session update.
        case agent(SessionUpdate)

        /// The client adds a local error entry with this code and message.
        case localError(code: ErrorCode, message: String)
    }

    /// The prefix of each id that a preview item gives. The position of the
    /// item follows it.
    private static let idPrefix = "preview-"

    /// Adds the entry of this item to a model, through the path that a live
    /// model uses for the same entry.
    ///
    /// - Parameters:
    ///   - model: The preview model.
    ///   - position: The position of the item in its list. It makes the id
    ///     of the entry.
    @MainActor
    func add(to model: SessionModel, at position: Int) {
        switch source(at: position) {
        case .agent(let update):
            model.apply(update)
        case .localError(let code, let message):
            model.appendError(code: code, message: message, data: nil)
        }
    }

    /// Tells where the entry of this item comes from in a live model.
    ///
    /// - Parameter position: The position of the item in its list.
    /// - Returns: The session update that an agent sends for the item, or
    ///   the local error that the client adds.
    private func source(at position: Int) -> Source {
        let id = "\(Self.idPrefix)\(position)"
        switch self {
        case .user(let text): return .agent(.userMessageChunk(Self.chunk(text, id: id)))
        case .agent(let text): return .agent(.agentMessageChunk(Self.chunk(text, id: id)))
        case .thought(let text): return .agent(.agentThoughtChunk(Self.chunk(text, id: id)))
        case .toolCall(let title, let kind, let status):
            let update = ToolCallUpdate(
                toolCallId: ToolCallId(rawValue: id),
                kind: .value(kind),
                status: .value(status),
                title: .value(title)
            )
            return .agent(.toolCallUpdate(update))
        case .plan(let entries):
            return .agent(.planUpdate(PlanUpdate(plan: .items(PlanItems(entries: entries, planId: PlanId(rawValue: id))))))
        case .terminal(let command, let output, let exitCode):
            return .agent(.terminalUpdate(Self.terminalUpdate(id: id, command: command, output: output, exitCode: exitCode)))
        case .error(let code, let message):
            return .localError(code: code, message: message)
        case .update(let update):
            return .agent(update)
        }
    }

    /// Makes a content chunk of one text block.
    ///
    /// - Parameters:
    ///   - text: The text of the block.
    ///   - id: The raw message id.
    /// - Returns: The chunk.
    private static func chunk(_ text: String, id: String) -> ContentChunk {
        ContentChunk(content: .text(TextContent(text: text)), messageId: MessageId(rawValue: id))
    }

    /// Makes the update of a terminal. The wire carries the output as base64
    /// bytes.
    ///
    /// - Parameters:
    ///   - id: The raw terminal id.
    ///   - command: The command that the terminal runs.
    ///   - output: The output text.
    ///   - exitCode: The exit code, or `nil` while the command runs.
    /// - Returns: The update.
    private static func terminalUpdate(id: String, command: String, output: String, exitCode: Int?) -> TerminalUpdate {
        TerminalUpdate(
            terminalId: TerminalId(rawValue: id),
            command: .value(command),
            exitStatus: exitCode.map { .value(TerminalExitStatus(exitCode: $0)) } ?? .unchanged,
            output: .value(TerminalOutput(data: Data(output.utf8).base64EncodedString()))
        )
    }
}
