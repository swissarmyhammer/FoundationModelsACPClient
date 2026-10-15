import Foundation
import FoundationModelsACP

// The requests of a session: the prompt, with its local pending user message
// and its error entry, the cancel of the work of the session, which also
// answers the pending permission requests, and the set-config-option request.
// Each request goes through the injected `SessionRequestSender`. A `_meta`
// parameter lets the caller give members of the `_meta` of the request.

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
    /// When the request goes out, the model records its W3C trace context in
    /// ``promptTraceMeta``, so a later cancel can link to its span.
    ///
    /// The prompt is mail: the agent answers when it accepts the message, and
    /// not when its work ends. The work comes after the response, as session
    /// updates. A second prompt while one is open is also accepted. To know
    /// when the work for this prompt ended, wait for the first `idle`
    /// ``agentState`` after the echo of the message id of the response.
    ///
    /// - Parameters:
    ///   - content: The content of the user message.
    ///   - meta: The `_meta` field of the request, for example the trace
    ///     parent, or `nil`.
    /// - Returns: The response, which names the inserted user message.
    /// - Throws: The error of the sender: `RequestError` on a peer error,
    ///   `ConnectionError` on a disconnect or a timeout, or
    ///   `CancellationError` when the calling task is cancelled.
    public func prompt(_ content: [ContentBlock], meta: JSONValue? = nil) async throws -> PromptResponse {
        let entry = UserMessageEntry(content: content, meta: meta)
        addPendingPrompt(entry)
        do {
            let request = PromptRequest(prompt: content, sessionId: sessionId, meta: meta)
            let response = try await requestSender.prompt(request) { sent in
                self.recordTraceContext(of: sent)
            }
            resolvePrompt(entry, with: response)
            return response
        } catch {
            failPrompt(entry)
            appendError(reporting: error)
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

    /// Appends the local error entry of an error that a request threw.
    ///
    /// Use this for a request that the host sent and that failed, so the
    /// entry has the same text and data as the entry that ``prompt(_:meta:)``
    /// adds. ``RequestError/init(reporting:)`` gives the code, the message,
    /// and the data of the entry. For example, a closed connection gives the
    /// message "The connection to the agent closed before the agent
    /// answered." and the data `{"connectionError": "closed"}`.
    ///
    /// - Parameter error: The error that the request threw.
    public func appendError(reporting error: any Error) {
        let failure = RequestError(reporting: error)
        appendError(code: failure.code, message: failure.message, data: failure.data)
    }

    /// Cancels the work of the session: answers each pending permission
    /// request with the `cancelled` outcome, answers each pending
    /// session-scoped elicitation with the `cancel` action, and then sends the
    /// `session/cancel` notification for this session.
    ///
    /// The ACP prompt lifecycle says that the client MUST respond to all
    /// pending `session/request_permission` requests with the `cancelled`
    /// outcome when it cancels. Each pending elicitation gets the `cancel`
    /// action with the reason ``ACPClient/clientCancelledReason`` in `_meta`,
    /// under ``ACPClient/elicitationReasonMetaKey``. Thus
    /// ``pendingPermissions`` and ``pendingElicitations`` are empty before the
    /// notification goes out. Both are cancelled also when the send fails,
    /// because the user asked to stop the work. The request-scoped
    /// elicitations of the ``ConnectionModel`` belong to a client request,
    /// not to the work of the session, so they stay pending.
    ///
    /// The model answers before it sends the notification, but the wire does
    /// not guarantee that the answers go out before `session/cancel`. The
    /// answers are correct in each order. An agent can also end a question
    /// itself when it gets `session/cancel`, so a tool of the agent can get
    /// either the reason "the client cancelled the work" or the reason of the
    /// agent (for example "run cancelled"), whichever comes first. The other
    /// message is safe: a `$/cancel_request` for a request that the client
    /// already answered does nothing, and a late answer to a request that the
    /// agent already ended is dropped.
    ///
    /// The agent confirms the cancellation with an idle `state_update` that
    /// has the `cancelled` stop reason, and not with this call. That idle can
    /// come later than the answer to the prompt, and after other updates of
    /// the work that the agent stops.
    ///
    /// The cancel acts on the work of the whole session, not on one prompt.
    /// Thus the `session/cancel` span starts in the trace context of the
    /// caller, as each other request does: it is a child of the span of the
    /// caller, or a root span when the caller has no span. It is never a
    /// child of a prompt span. The span links to one earlier span:
    ///
    /// - the span that the W3C `traceparent` in `meta` names, when `meta`
    ///   holds one; or else
    /// - the span of the last prompt of this model (``promptTraceMeta``),
    ///   when there is one.
    ///
    /// The `_meta` of the notification keeps each member of `meta`, and the
    /// trace context of the cancel span replaces its trace context members.
    ///
    /// - Parameter meta: The `_meta` field of the notification, or `nil`.
    /// - Throws: The error of the sender: `ConnectionError` after a
    ///   disconnect.
    public func cancel(meta: JSONValue? = nil) async throws {
        permissions.cancelAll()
        cancelPendingElicitations(reason: ACPClient.clientCancelledReason)
        let link = TraceContextMeta.extract(from: meta) == nil ? promptTraceMeta : meta
        try await requestSender.cancel(CancelSessionNotification(sessionId: sessionId, meta: meta), linkingTo: link)
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

    /// Records the W3C trace context of a prompt request as it goes out.
    ///
    /// Only the trace context members are kept, so each other `_meta` member
    /// of the prompt stays out of a cancel that gives this value.
    ///
    /// - Parameter request: The prompt request with its final `_meta`.
    private func recordTraceContext(of request: PromptRequest) {
        promptTraceMeta = TraceContextMeta.extract(from: request.meta).map { $0.inject(into: nil) }
    }
}

extension RequestError {
    /// The key of the `data` member that names the case of a
    /// `ConnectionError`.
    private static let connectionErrorDataKey = "connectionError"

    /// Gives the JSON-RPC form of an error that a request threw, for the
    /// error entry of the transcript and for ``AuthFailure/Reason/request(_:)``.
    ///
    /// A `RequestError` stays as the peer sent it. A `ConnectionError` has no
    /// JSON-RPC code, so it becomes `internalError` with a message of the
    /// client and with the name of its case in the `connectionError` member
    /// of `data`:
    ///
    /// - `ConnectionError.closed`: "The connection to the agent closed before
    ///   the agent answered.", and `{"connectionError": "closed"}`.
    /// - `ConnectionError.timedOut`: "The request timed out before the agent
    ///   answered.", and `{"connectionError": "timedOut"}`.
    ///
    /// A cancellation becomes `requestCancelled`. Each other error becomes
    /// `internalError` with its description as the detail.
    ///
    /// A host that sends a request itself uses this initializer, or
    /// ``SessionModel/appendError(reporting:)``, so its error entry is the
    /// same as the entry of the client.
    ///
    /// - Parameter error: The error that the request threw.
    public init(reporting error: any Error) {
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
