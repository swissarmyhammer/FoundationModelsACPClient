import FoundationModelsACP
import Synchronization

/// A request sender for a preview ``SessionModel``. It never uses the
/// network, and it never opens a process or a socket.
///
/// Give it to ``SessionModel/preview(sessionId:cwd:transcript:availableCommands:configOptions:mcpServers:pendingPermissions:requestSender:)``.
/// ``SessionModel/prompt(_:meta:)`` then works as it does on a live model:
/// the transcript shows the prompt at once as a local user message in the
/// ``SendState/pending`` state, and the answer of this sender sets
/// ``SendState/sent``. A prompt that this sender does not answer stays
/// pending until its task is cancelled, and then gets ``SendState/failed``.
///
/// ``SessionModel/cancel(meta:)`` and
/// ``SessionModel/setConfigOption(_:)`` send nothing, and do nothing more
/// than the model does itself.
public final class PreviewSessionRequestSender: SessionRequestSender {
    /// How the sender answers a `session/prompt` request.
    public enum PromptAnswer: Hashable, Sendable {
        /// Answer each prompt at once, with a new message id for each prompt.
        case respond

        /// Never answer a prompt. The prompt waits until its task is
        /// cancelled.
        case never
    }

    /// The prefix of the message id of each answer. The number of the
    /// prompt follows it.
    private static let messageIdPrefix = "preview-prompt-"

    /// How the sender answers a prompt.
    private let answer: PromptAnswer

    /// The number of prompts that the sender answered.
    private let answeredPromptCount = Mutex(0)

    /// Makes a sender.
    ///
    /// - Parameter answer: How the sender answers a prompt.
    public init(answer: PromptAnswer = .respond) {
        self.answer = answer
    }

    /// Gives the request to `willSend`, and then answers it as ``answer``
    /// tells.
    ///
    /// - Parameters:
    ///   - request: The prompt request.
    ///   - willSend: Gets the request before the answer.
    /// - Returns: A response with a message id that no earlier answer of
    ///   this sender gave.
    /// - Throws: `CancellationError` when the task of a prompt that the
    ///   sender never answers is cancelled.
    func prompt(
        _ request: PromptRequest,
        willSend: @MainActor @Sendable (PromptRequest) -> Void
    ) async throws -> PromptResponse {
        await willSend(request)
        switch answer {
        case .respond:
            return PromptResponse(messageId: nextMessageId())
        case .never:
            try await CancellationWait.untilCancelled()
        }
    }

    /// Sends nothing.
    ///
    /// - Parameters:
    ///   - notification: The cancel notification.
    ///   - link: The trace context that the cancel links to; not used.
    func cancel(_ notification: CancelSessionNotification, linkingTo link: JSONValue?) async throws {}

    /// Sends nothing.
    ///
    /// - Parameter request: The set-config-option request.
    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {}

    /// Gives the message id of the next answer.
    ///
    /// - Returns: The message id.
    private func nextMessageId() -> MessageId {
        let number = answeredPromptCount.withLock { count in
            count += 1
            return count
        }
        return MessageId(rawValue: "\(Self.messageIdPrefix)\(number)")
    }
}
