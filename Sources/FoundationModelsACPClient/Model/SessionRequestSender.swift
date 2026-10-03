import FoundationModelsACP

/// Sends the requests of one session to the agent.
///
/// ``SessionModel`` sends each request through this seam. The connection
/// model gives the real sender, which sends over the ACP connection. Tests
/// give a fake sender, so they control when and how each request answers.
protocol SessionRequestSender: Sendable {
    /// Sends `session/prompt`.
    ///
    /// - Parameter request: The prompt request.
    /// - Returns: The response, which names the user message that the agent
    ///   inserted.
    /// - Throws: `RequestError` on a peer error, `ConnectionError` on a
    ///   disconnect or a timeout, or `CancellationError` when the calling task
    ///   is cancelled.
    func prompt(_ request: PromptRequest) async throws -> PromptResponse

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
