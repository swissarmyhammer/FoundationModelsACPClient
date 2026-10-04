import FoundationModelsACP

/// Sends the requests of one session over an ACP connection.
///
/// ``ConnectionModel`` gives this sender to each session model that it makes,
/// so the prompt, the cancel, and the configuration change of the model go to
/// the agent over the connection that opened the session.
///
/// Each request goes out in a client request span, through
/// ``ClientRequestSpan/send(_:parent:through:)``: the span, the request
/// metrics, and the W3C trace context in the `_meta` of the request. The
/// `_meta` that the caller gives stays, and the trace context is added to it.
struct ConnectionSessionRequestSender: SessionRequestSender {
    /// The connection that carries the requests.
    let connection: ClientSideConnection

    /// Sends `session/prompt` in a client request span.
    ///
    /// `willSend` gets the request inside the span, with the W3C trace context
    /// of the span in its `_meta`, before the request goes out.
    ///
    /// - Parameters:
    ///   - request: The prompt request.
    ///   - willSend: Gets the request with its traced `_meta`.
    /// - Returns: The response of the agent.
    /// - Throws: `RequestError` on a peer error, `ConnectionError` on a
    ///   disconnect or a timeout, or `CancellationError` when the calling task
    ///   is cancelled.
    func prompt(
        _ request: PromptRequest,
        willSend: @MainActor @Sendable (PromptRequest) -> Void
    ) async throws -> PromptResponse {
        try await ClientRequestSpan.send(request) { traced in
            await willSend(traced)
            return try await connection.prompt(traced)
        }
    }

    /// Sends the `session/cancel` notification in a client request span.
    ///
    /// When the `_meta` of the notification holds a W3C `traceparent`, for
    /// example the `_meta` of the `session/prompt` of the turn, the span is a
    /// child of the span that the `traceparent` names. The cancel then joins
    /// the trace of the turn, also when it runs on another task.
    ///
    /// - Parameter notification: The cancel notification.
    /// - Throws: `ConnectionError` after a disconnect.
    func cancel(_ notification: CancelSessionNotification) async throws {
        try await ClientRequestSpan.send(
            notification,
            parent: ClientRequestSpan.ParentContext(extractingFrom: notification.meta)
        ) { try await connection.sessionCancel($0) }
    }

    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {
        _ = try await ClientRequestSpan.send(request) { try await connection.setSessionConfigOption($0) }
    }
}
