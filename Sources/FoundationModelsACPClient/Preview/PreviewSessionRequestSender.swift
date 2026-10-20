import Foundation
import FoundationModelsACP
import Observation

/// A request sender for a preview ``SessionModel``. It never uses the
/// network, and it never opens a process or a socket.
///
/// Give it to ``SessionModel/preview(sessionId:cwd:transcript:availableCommands:configOptions:mcpServers:pendingPermissions:pendingElicitations:requestSender:)``.
/// ``SessionModel/prompt(_:meta:)`` then works as it does on a live model:
/// the transcript shows the prompt at once as a local user message in the
/// ``SendState/pending`` state, and the answer of this sender sets
/// ``SendState/sent``. A prompt that this sender does not answer stays
/// pending until its task is cancelled, and then gets ``SendState/failed``.
///
/// ``SessionModel/cancel(meta:)`` and
/// ``SessionModel/setConfigOption(_:)`` send nothing, and do nothing more
/// than the model does itself.
///
/// The sender records each message that the model sends, in ``sent``, so a
/// test can read what a Send, a Stop, or an answer of the user sent:
///
/// ```swift
/// let sender = PreviewSessionRequestSender()
/// let session = SessionModel.preview(requestSender: sender)
/// _ = try await session.prompt([.text(TextContent(text: "Hello"))])
/// #expect(sender.sent == [.prompt(PromptRequest(prompt: [.text(TextContent(text: "Hello"))], sessionId: session.sessionId))])
/// ```
///
/// Give a sender also as the `recorder` of
/// ``ConnectionModel/preview(state:sessions:openSessions:authState:initializeResponse:pendingElicitations:recorder:)``.
/// It then records the answer to each request-scoped elicitation of the
/// preview connection in ``sent``, with the same
/// ``Sent/elicitationResponse(id:response:)`` shape.
@MainActor @Observable
public final class PreviewSessionRequestSender: SessionRequestSender {
    /// How the sender answers a `session/prompt` request.
    public enum PromptAnswer: Hashable, Sendable {
        /// Answer each prompt at once, with a new message id for each prompt.
        case respond

        /// Never answer a prompt. The prompt waits until its task is
        /// cancelled.
        case never
    }

    /// One message that the model sent through this sender.
    public enum Sent: Hashable, Sendable {
        /// A `session/prompt` request, as it went out.
        case prompt(PromptRequest)

        /// A `session/cancel` notification.
        case cancel(CancelSessionNotification)

        /// A `session/set_config_option` request.
        case setConfigOption(SetSessionConfigOptionRequest)

        /// The answer to a pending permission request. The id is the
        /// ``PendingPermissionRequest/id`` of the request, as it was in
        /// ``SessionModel/pendingPermissions``.
        case permissionResponse(id: PendingPermissionRequest.ID, response: RequestPermissionResponse)

        /// The answer to a pending elicitation, as the spec's action object.
        /// The id is the ``PendingElicitation/id`` of the elicitation, as it
        /// was in ``SessionModel/pendingElicitations``, or in
        /// ``ConnectionModel/pendingElicitations`` for a request-scoped
        /// elicitation of a preview connection.
        case elicitationResponse(id: PendingElicitation.ID, response: CreateElicitationResponse)
    }

    /// The prefix of the message id of each answer. The number of the
    /// prompt follows it.
    private static let messageIdPrefix = "preview-prompt-"

    /// Each message that the model sent through this sender, in send order.
    public private(set) var sent: [Sent] = []

    /// How the sender answers a prompt.
    @ObservationIgnored private let answer: PromptAnswer

    /// The number of prompts that the sender answered.
    @ObservationIgnored private var answeredPromptCount = 0

    /// Makes a sender.
    ///
    /// - Parameter answer: How the sender answers a prompt.
    public init(answer: PromptAnswer = .respond) {
        self.answer = answer
    }

    /// Gives the request to `willSend`, records it in ``sent``, and then
    /// answers it as ``answer`` tells.
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
        willSend(request)
        sent.append(.prompt(request))
        switch answer {
        case .respond:
            return PromptResponse(messageId: nextMessageId())
        case .never:
            try await CancellationWait.untilCancelled()
        }
    }

    /// Records the notification in ``sent``, and sends nothing.
    ///
    /// - Parameters:
    ///   - notification: The cancel notification.
    ///   - link: The trace context that the cancel links to; not used.
    func cancel(_ notification: CancelSessionNotification, linkingTo link: JSONValue?) async throws {
        sent.append(.cancel(notification))
    }

    /// Records the request in ``sent``, and sends nothing.
    ///
    /// - Parameter request: The set-config-option request.
    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {
        sent.append(.setConfigOption(request))
    }

    /// Records the answer to a pending permission request in ``sent``.
    ///
    /// - Parameters:
    ///   - id: The local id of the pending request.
    ///   - response: The answer of the model.
    func didAnswerPermission(_ id: PendingPermissionRequest.ID, with response: RequestPermissionResponse) {
        sent.append(.permissionResponse(id: id, response: response))
    }

    /// Records the answer to a pending elicitation in ``sent``.
    ///
    /// - Parameters:
    ///   - id: The local id of the pending elicitation.
    ///   - response: The answer of the model.
    func didAnswerElicitation(_ id: PendingElicitation.ID, with response: CreateElicitationResponse) {
        sent.append(.elicitationResponse(id: id, response: response))
    }

    /// Gives the message id of the next answer.
    ///
    /// - Returns: The message id.
    private func nextMessageId() -> MessageId {
        answeredPromptCount += 1
        return MessageId(rawValue: "\(Self.messageIdPrefix)\(answeredPromptCount)")
    }
}
