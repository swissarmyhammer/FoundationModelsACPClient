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
///
/// Each error that a prompt or a configuration change throws goes to
/// ``requestDidFail`` before the call throws it again. Thus the model that
/// made the sender can read the error, for example a `-32000` answer of the
/// agent.
struct ConnectionSessionRequestSender: SessionRequestSender {
    /// The connection that carries the requests.
    let connection: ClientSideConnection

    /// Gets each error that a prompt or a configuration change threw, before
    /// the call throws it again.
    let requestDidFail: @MainActor @Sendable (any Error) -> Void

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
    ///   is cancelled, after ``requestDidFail`` got it.
    func prompt(
        _ request: PromptRequest,
        willSend: @MainActor @Sendable (PromptRequest) -> Void
    ) async throws -> PromptResponse {
        try await reportingFailure {
            try await ClientRequestSpan.send(request) { traced in
                await willSend(traced)
                return try await connection.prompt(traced)
            }
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

    /// Sends `session/set_config_option` in a client request span.
    ///
    /// - Parameter request: The set-config-option request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on a
    ///   disconnect or a timeout, after ``requestDidFail`` got it.
    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {
        try await reportingFailure {
            _ = try await ClientRequestSpan.send(request) { try await connection.setSessionConfigOption($0) }
        }
    }

    /// Runs one request, and gives each error that it throws to
    /// ``requestDidFail`` before it throws the error again.
    ///
    /// - Parameter send: Sends the request.
    /// - Returns: The value of `send`.
    /// - Throws: The error of `send`.
    private func reportingFailure<Output>(
        _ send: nonisolated(nonsending) () async throws -> Output
    ) async throws -> Output {
        do {
            return try await send()
        } catch {
            await requestDidFail(error)
            throw error
        }
    }
}
