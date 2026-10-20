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
    /// `willSend` sees that trace context before the request goes out.
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
    /// - Parameters:
    ///   - notification: The cancel notification.
    ///   - link: A `_meta` value whose W3C `traceparent` names the span that
    ///     the cancel span links to, or `nil` for no link.
    /// - Throws: `ConnectionError` after a disconnect.
    func cancel(_ notification: CancelSessionNotification, linkingTo link: JSONValue?) async throws

    /// Sends `session/set_config_option`.
    ///
    /// The agent reports the new values through a `config_option_update`
    /// session update, so the sender does not give the response.
    ///
    /// - Parameter request: The set-config-option request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on a
    ///   disconnect or a timeout.
    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws

    /// Gets the answer that the model gave to one pending permission request.
    ///
    /// The model calls it when a resolution removes the request from
    /// ``SessionModel/pendingPermissions``: a selection, a cancel of the
    /// request, or a cancel of the work. The answer goes to the agent as the
    /// return value of its request, and not through this sender, so the
    /// default implementation does nothing. A sender with no connection can
    /// record the answer here.
    ///
    /// - Parameters:
    ///   - id: The local id of the pending request.
    ///   - response: The answer of the model.
    @MainActor
    func didAnswerPermission(_ id: PendingPermissionRequest.ID, with response: RequestPermissionResponse)

    /// Gets the answer that the model gave to one pending session-scoped
    /// elicitation.
    ///
    /// The model calls it when a resolution removes the elicitation from
    /// ``SessionModel/pendingElicitations``. As for a permission answer, the
    /// default implementation does nothing.
    ///
    /// - Parameters:
    ///   - id: The local id of the pending elicitation.
    ///   - response: The answer of the model, as the spec's action object.
    @MainActor
    func didAnswerElicitation(_ id: PendingElicitation.ID, with response: CreateElicitationResponse)
}

extension SessionRequestSender {
    /// Does nothing: the connection sends the answer as the return value of
    /// the request of the agent.
    ///
    /// - Parameters:
    ///   - id: The local id of the pending request; not used.
    ///   - response: The answer of the model; not used.
    @MainActor
    func didAnswerPermission(_ id: PendingPermissionRequest.ID, with response: RequestPermissionResponse) {}

    /// Does nothing: the connection sends the answer as the return value of
    /// the request of the agent.
    ///
    /// - Parameters:
    ///   - id: The local id of the pending elicitation; not used.
    ///   - response: The answer of the model; not used.
    @MainActor
    func didAnswerElicitation(_ id: PendingElicitation.ID, with response: CreateElicitationResponse) {}
}
