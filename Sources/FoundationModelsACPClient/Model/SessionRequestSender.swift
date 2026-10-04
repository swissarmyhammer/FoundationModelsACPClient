import FoundationModelsACP

/// Sends the requests of one session to the agent.
///
/// ``SessionModel`` sends each request through this seam. The connection
/// model gives the real sender, which sends over the ACP connection. Tests
/// give a fake sender, so they control when and how each request answers.
protocol SessionRequestSender: Sendable {
    /// Sends `session/prompt`.
    ///
    /// The sender calls `willSend` one time, with the request exactly as it
    /// goes out, before the request goes out. The real sender gives the
    /// request the W3C trace context of its client span in `_meta`, so
    /// `willSend` sees that trace context while the turn still runs.
    ///
    /// - Parameters:
    ///   - request: The prompt request.
    ///   - willSend: Gets the request with its final `_meta`, on the main
    ///     actor, before the request goes out.
    /// - Returns: The response, which names the user message that the agent
    ///   inserted.
    /// - Throws: `RequestError` on a peer error, `ConnectionError` on a
    ///   disconnect or a timeout, or `CancellationError` when the calling task
    ///   is cancelled.
    func prompt(
        _ request: PromptRequest,
        willSend: @MainActor @Sendable (PromptRequest) -> Void
    ) async throws -> PromptResponse

    /// Sends the `session/cancel` notification.
    ///
    /// - Parameter notification: The cancel notification.
    /// - Throws: `ConnectionError` after a disconnect.
    func cancel(_ notification: CancelSessionNotification) async throws

    /// Sends `session/set_config_option`.
    ///
    /// The agent reports the new values through a `config_option_update`
    /// session update, so the sender does not give the response.
    ///
    /// - Parameter request: The set-config-option request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on a
    ///   disconnect or a timeout.
    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws
}
