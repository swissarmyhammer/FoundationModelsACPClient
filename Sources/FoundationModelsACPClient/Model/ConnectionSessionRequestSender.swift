import FoundationModelsACP

/// Sends the requests of one session over an ACP connection.
///
/// ``ConnectionModel`` gives this sender to each session model that it makes,
/// so the prompt, the cancel, and the configuration change of the model go to
/// the agent over the connection that opened the session.
struct ConnectionSessionRequestSender: SessionRequestSender {
    /// The connection that carries the requests.
    let connection: ClientSideConnection

    func prompt(_ request: PromptRequest) async throws -> PromptResponse {
        try await connection.prompt(request)
    }

    func cancel(_ notification: CancelSessionNotification) async throws {
        try await connection.sessionCancel(notification)
    }

    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {
        _ = try await connection.setSessionConfigOption(request)
    }
}
