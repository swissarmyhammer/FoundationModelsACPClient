import FoundationModelsACP

/// The request sender of a read-only ``SessionModel``: a sender with no
/// connection, which sends nothing.
///
/// Each method of the model that sends to the agent checks
/// ``SessionModel/isReadOnly`` first and throws
/// ``SessionModelError/readOnly`` before it calls the sender. This sender is
/// a second barrier: each call throws the same error and sends nothing.
struct ReadOnlySessionRequestSender: SessionRequestSender {
    /// Sends nothing.
    ///
    /// - Parameters:
    ///   - request: The prompt request; not sent.
    ///   - willSend: Not called.
    /// - Returns: Never returns.
    /// - Throws: ``SessionModelError/readOnly`` always.
    func prompt(
        _ request: PromptRequest,
        willSend: @MainActor @Sendable (PromptRequest) -> Void
    ) async throws -> PromptResponse {
        throw SessionModelError.readOnly
    }

    /// Sends nothing.
    ///
    /// - Parameters:
    ///   - notification: The cancel notification; not sent.
    ///   - link: The link of the cancel span; not used.
    /// - Throws: ``SessionModelError/readOnly`` always.
    func cancel(_ notification: CancelSessionNotification, linkingTo link: JSONValue?) async throws {
        throw SessionModelError.readOnly
    }

    /// Sends nothing.
    ///
    /// - Parameter request: The set-config-option request; not sent.
    /// - Throws: ``SessionModelError/readOnly`` always.
    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {
        throw SessionModelError.readOnly
    }
}
