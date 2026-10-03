import FoundationModelsACP

extension ClientSideConnection {
    /// Runs `handler` on the main actor one time, when this connection
    /// closes, with the reason of the close.
    ///
    /// The wait runs in a task of its own, and the task ends when the
    /// connection closes. No handle is given: the wait for the close does not
    /// stop on a cancel, so a cancel would change nothing.
    ///
    /// The wait must never run in an inbound handler of the served `Client`.
    /// The close reason comes only after each inbound handler ended, so a wait
    /// inside one never ends. When the connection is already closed,
    /// `handler` runs at once.
    ///
    /// - Parameter handler: The function that gets the reason of the close.
    func onClose(_ handler: @escaping @MainActor @Sendable (ConnectionCloseReason) -> Void) {
        Task { @MainActor in
            let reason = await closed
            handler(reason)
        }
    }
}
