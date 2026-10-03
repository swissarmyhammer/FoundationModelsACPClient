import FoundationModelsACP

// The stream life of a session: the attached update subscription, the
// missed-updates mark, the replay of a `session/resume` request, and the
// close. Only the connection model calls these members; the UI never
// subscribes itself, and reads only the observable results.

extension SessionModel {
    /// The replay of a `session/resume` request.
    enum ReplayPhase: Hashable, Sendable {
        /// No replay runs.
        case idle

        /// The client sent a `session/resume` request with this cursor, and
        /// waits for its response. A `nil` cursor asks for no replay.
        case replaying(from: ReplayFrom?)
    }

    /// Whether a `session/resume` request runs, from the moment before the
    /// request goes out until its response or its failure.
    public var isReplaying: Bool {
        replayPhase != .idle
    }

    // MARK: - Attachment

    /// Folds the updates of a subscription into this model, in order.
    ///
    /// One main-actor task receives the updates and gives each one to
    /// ``apply(_:)``. A subscription with missed updates sets
    /// ``hasMissedUpdates``. When the subscription ends, each ``updateTap()``
    /// stream ends too. A later call replaces the earlier subscription.
    ///
    /// - Parameter subscription: The subscription that
    ///   `ClientSideConnection.subscribe(to:)` gave for this session.
    func attach(_ subscription: SessionUpdateSubscription) {
        if subscription.hasMissedUpdates {
            hasMissedUpdates = true
        }
        streamTask?.cancel()
        let updates = subscription.updates
        streamTask = Task { @MainActor [weak self] in
            for await update in updates {
                self?.apply(update)
            }
            self?.subscriptionDidEnd()
        }
    }

    /// Ends each tap when the connection ended the subscription.
    ///
    /// A cancelled task ends the loop as well. The close and a replaced
    /// subscription cancel the task, and neither must end the taps here: the
    /// close ends them itself, and a replaced subscription keeps them open.
    private func subscriptionDidEnd() {
        guard !Task.isCancelled else { return }
        finishUpdateTaps()
    }

    // MARK: - Replay

    /// Marks the start of a `session/resume` request.
    ///
    /// Call this before the request goes out, with the `replayFrom` cursor of
    /// the request. When the request asks for a replay and the model already
    /// has a transcript, the model first clears its transcript and its
    /// last-value state, because a replayed chunk appends again and would
    /// double the text.
    ///
    /// - Parameter replayFrom: The `replayFrom` field of the request that the
    ///   client sends, or `nil` for no replay.
    func beginReplay(replayFrom: ReplayFrom?) {
        if replayFrom != nil, !transcript.isEmpty {
            flushPendingChunks()
            resetTranscript()
        }
        replayPhase = .replaying(from: replayFrom)
    }

    /// Marks the end of a `session/resume` request.
    ///
    /// The model folds the buffered replay chunks at once. A successful replay
    /// sets ``history`` to the retained history of its cursor. A successful
    /// replay from the start gives the full retained history, so it clears
    /// ``hasMissedUpdates``. A failure, and a resume with no replay, keep both
    /// values.
    ///
    /// - Parameter succeeded: Whether the agent answered the request with a
    ///   result.
    func endReplay(succeeded: Bool) {
        let phase = replayPhase
        replayPhase = .idle
        flushPendingChunks()
        guard succeeded, case .replaying(from: let replayFrom?) = phase else { return }
        history = .retained(replayFrom: replayFrom)
        if case .start = replayFrom {
            hasMissedUpdates = false
        }
    }

    // MARK: - Close

    /// Closes the model.
    ///
    /// The model folds the buffered chunks, stops the task of the
    /// subscription, ends each ``updateTap()`` stream, and cancels each
    /// pending permission request and elicitation. After the close,
    /// ``apply(_:)`` changes nothing.
    func markClosed() {
        flushPendingChunks()
        streamTask?.cancel()
        streamTask = nil
        finishUpdateTaps()
        cancelAllPending()
        isClosed = true
    }
}
