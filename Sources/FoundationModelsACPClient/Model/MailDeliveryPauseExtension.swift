import FoundationModelsACP
import Observation

/// The built-in extension that keeps the last pause of the mail delivery of
/// a session.
///
/// The extension takes each `_mail_delivery_paused` update, so the update
/// never goes to the engine and adds no transcript entry. It sees each user
/// message and each user message chunk too: such an update clears the pause,
/// and the extension does not take it, so it still goes to the engine.
/// ``SessionModel/mailDeliveryPause`` reads the pause.
struct MailDeliveryPauseExtension: ClientModelExtension {
    /// The session state of the extension: the pause of one session.
    @MainActor @Observable
    final class SessionState {
        /// The last pause that the agent reported, or `nil` when the mail
        /// delivery of the session is not paused.
        var pause: MailDeliveryPause?
    }

    @MainActor func makeSessionState(for sessionId: SessionId) -> SessionState {
        SessionState()
    }

    /// Takes each `_mail_delivery_paused` update: a valid one replaces the
    /// pause. Clears the pause at each user message and each user message
    /// chunk, and does not take them.
    ///
    /// - Parameters:
    ///   - update: The session update.
    ///   - state: The session state.
    /// - Returns: `true` for each `_mail_delivery_paused` update.
    @MainActor func apply(_ update: SessionUpdate, to state: SessionState) -> Bool {
        guard !MailDeliveryPause.isPauseUpdate(update) else {
            if let pause = MailDeliveryPause.decode(update) {
                state.pause = pause
            }
            return true
        }
        if case .userMessage = update {
            state.pause = nil
        } else if case .userMessageChunk = update {
            state.pause = nil
        }
        return false
    }
}
