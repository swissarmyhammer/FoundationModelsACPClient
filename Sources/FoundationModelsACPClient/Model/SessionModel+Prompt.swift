import Foundation
import FoundationModelsACP

// The requests of a session: the prompt, with its local pending user message
// and its error entry, the cancel notification, and the set-config-option
// request. Each request goes through the injected `SessionRequestSender`.
// A `_meta` parameter lets the caller give the trace parent of the request.

extension SessionModel {
    /// Sends `session/prompt` with the content as the user message.
    ///
    /// Before the request goes out, the transcript shows the prompt as a
    /// local user message: ``EntryOrigin/local``, ``SendState/pending``, and
    /// no message id. The prompt response or the echoed `user_message` with
    /// the same id, whichever arrives first, sets the message id and
    /// ``SendState/sent``. The entry keeps its object and its identity, and
    /// the echo adds no second entry.
    ///
    /// When the request fails, the entry gets ``SendState/failed``, the
    /// transcript gets a local error entry with the JSON-RPC code, message,
    /// and data of the failure, and the call throws the error again.
    ///
    /// - Parameters:
    ///   - content: The content of the user message.
    ///   - meta: The `_meta` field of the request, for example the trace
    ///     parent, or `nil`.
    /// - Returns: The response, which names the inserted user message. The
    ///   turn itself goes on after the response, as session updates.
    /// - Throws: The error of the sender: `RequestError` on a peer error,
    ///   `ConnectionError` on a disconnect or a timeout, or
    ///   `CancellationError` when the calling task is cancelled.
    public func prompt(_ content: [ContentBlock], meta: JSONValue? = nil) async throws -> PromptResponse {
        let entry = UserMessageEntry(content: content, meta: meta)
        addPendingPrompt(entry)
        do {
            let response = try await requestSender.prompt(PromptRequest(prompt: content, sessionId: sessionId, meta: meta))
            resolvePrompt(entry, with: response)
            return response
        } catch {
            failPrompt(entry)
            appendError(RequestError(reporting: error))
            throw error
        }
    }

    /// Appends a local error entry to the transcript.
    ///
    /// Use this for a request that the model did not send, for example a
    /// login, so the error shows in the transcript in its order.
    ///
    /// - Parameters:
    ///   - code: The JSON-RPC error code.
    ///   - message: The error message.
    ///   - data: The JSON-RPC error data, or `nil`.
    public func appendError(code: ErrorCode, message: String, data: JSONValue?) {
        appendLocalEntry(.error(ErrorEntry(code: code, message: message, data: data)))
    }

    /// Sends the `session/cancel` notification for this session.
    ///
    /// The agent confirms the cancellation with an idle `state_update` that
    /// has the `cancelled` stop reason, and not with this call.
    ///
    /// When `meta` holds a W3C `traceparent`, for example the `_meta` that
    /// the `session/prompt` of the turn sent, the `session/cancel` span is a
    /// child of the span that the `traceparent` names, so the cancel joins
    /// the trace of the turn.
    ///
    /// - Parameter meta: The `_meta` field of the notification, for example
    ///   the trace parent, or `nil`.
    /// - Throws: The error of the sender: `ConnectionError` after a
    ///   disconnect.
    public func cancel(meta: JSONValue? = nil) async throws {
        try await requestSender.cancel(CancelSessionNotification(sessionId: sessionId, meta: meta))
    }

    /// Sends `session/set_config_option` as the caller made it.
    ///
    /// The agent reports the new values through a `config_option_update`
    /// session update, which sets ``configOptions``.
    ///
    /// - Parameter request: The set-config-option request.
    /// - Throws: The error of the sender: `RequestError` on a peer error, or
    ///   `ConnectionError` on a disconnect or a timeout.
    public func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {
        try await requestSender.setConfigOption(request)
    }

    /// Appends the local error entry of a failed request.
    ///
    /// - Parameter failure: The JSON-RPC error of the request.
    private func appendError(_ failure: RequestError) {
        appendError(code: failure.code, message: failure.message, data: failure.data)
    }
}

extension RequestError {
    /// The key of the `data` member that names the case of a
    /// `ConnectionError`.
    private static let connectionErrorDataKey = "connectionError"

    /// Gives the JSON-RPC form of an error that a request threw, for the
    /// error entry of the transcript.
    ///
    /// A `RequestError` stays as the peer sent it. A `ConnectionError` has no
    /// JSON-RPC code, so it becomes `internalError` with the name of its case
    /// in `data`. A cancellation becomes `requestCancelled`. Each other error
    /// becomes `internalError` with its description as the detail.
    ///
    /// - Parameter error: The error that the request threw.
    init(reporting error: any Error) {
        switch error {
        case let requestError as RequestError:
            self = requestError
        case let connectionError as ConnectionError:
            self = RequestError(
                code: .internalError,
                message: connectionError.reportMessage,
                data: .object([Self.connectionErrorDataKey: .string("\(connectionError)")])
            )
        case is CancellationError:
            self = .requestCancelled
        default:
            self = .internalError(detail: String(describing: error))
        }
    }
}

extension ConnectionError {
    /// The message of the error entry for this failure.
    fileprivate var reportMessage: String {
        switch self {
        case .closed: "The connection to the agent closed before the agent answered."
        case .timedOut: "The request timed out before the agent answered."
        }
    }
}
