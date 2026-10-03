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

    /// The `session/resume` requests of the running replay, matched to their
    /// markers by the wire id of the request.
    ///
    /// The start of a request comes from the outgoing-request events of the
    /// connection, and its marker comes from the stream of the session. The
    /// two streams have no common order, so either one can come first. A
    /// marker whose request did not start during the replay is the marker of
    /// an earlier request, for example a resume that its caller cancelled
    /// after the request went out. That marker never ends the replay.
    struct ReplayRequests {
        /// The wire ids of the `session/resume` requests that started during
        /// the running replay.
        private var started: Set<RequestId> = []

        /// The outcome of each `session/resume` marker that came before the
        /// start of its request, keyed by the wire id of the request.
        private var finishedBeforeStart: [RequestId: OutgoingRequestOutcome] = [:]

        /// Records the start of a `session/resume` request.
        ///
        /// - Parameter requestId: The wire id of the request.
        /// - Returns: The outcome of the request when its marker came first,
        ///   or `nil` when the marker did not come yet.
        mutating func didStart(_ requestId: RequestId) -> OutgoingRequestOutcome? {
            if let outcome = finishedBeforeStart.removeValue(forKey: requestId) {
                return outcome
            }
            started.insert(requestId)
            return nil
        }

        /// Records the marker of a `session/resume` request.
        ///
        /// - Parameters:
        ///   - requestId: The wire id of the request.
        ///   - outcome: How the request finished.
        /// - Returns: The outcome when the request started during the replay,
        ///   or `nil` when its start did not come yet.
        mutating func didFinish(_ requestId: RequestId, outcome: OutgoingRequestOutcome) -> OutgoingRequestOutcome? {
            guard started.contains(requestId) else {
                finishedBeforeStart[requestId] = outcome
                return nil
            }
            return outcome
        }
    }

    /// Whether a `session/resume` request runs, from the moment before the
    /// request goes out until its response or its failure.
    public var isReplaying: Bool {
        replayPhase != .idle
    }

    // MARK: - Attachment

    /// Folds the events of a subscription into this model, in order.
    ///
    /// One main-actor task receives the events. It gives each update to
    /// ``apply(_:)``, and it ends the running replay at the marker of its
    /// `session/resume` request. A subscription with missed updates sets
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
        let events = subscription.updates
        streamTask = Task { @MainActor [weak self] in
            for await event in events {
                self?.receive(event)
            }
            self?.subscriptionDidEnd()
        }
    }

    /// Receives one event of the attached subscription.
    ///
    /// - Parameter event: The event, in wire order.
    private func receive(_ event: SessionStreamEvent) {
        switch event {
        case .update(let update):
            apply(update)
        case .requestFinished(let requestId, let method, let outcome):
            requestDidFinish(requestId, method: method, outcome: outcome)
        }
    }

    /// Ends the running replay when the marker of its `session/resume`
    /// request arrives.
    ///
    /// The connection yields the marker at the wire position of the
    /// response, after each replayed update. Thus, at the marker, the model
    /// applied the whole replay. Only the marker of a request that started
    /// during the replay ends it, and ``replayRequestDidStart(_:)`` gives
    /// those starts. When the start did not come yet, the model keeps the
    /// marker until it comes. The marker of another request changes nothing.
    ///
    /// - Parameters:
    ///   - requestId: The wire id of the finished request.
    ///   - method: The wire method of the finished request.
    ///   - outcome: How the request finished.
    private func requestDidFinish(_ requestId: RequestId, method: String, outcome: OutgoingRequestOutcome) {
        guard method == ClientRequestSpan.Method.resumeSession, isReplaying,
            let finished = replayRequests.didFinish(requestId, outcome: outcome)
        else { return }
        endReplay(succeeded: finished == .succeeded)
    }

    /// Records that a `session/resume` request started during the running
    /// replay.
    ///
    /// The connection model calls this for each `session/resume` request that
    /// the connection starts while the replay runs. A request of another
    /// session never gives a marker in the stream of this session, so its id
    /// changes nothing. When the marker of the request came first, the replay
    /// ends now. When no replay runs, the call changes nothing.
    ///
    /// - Parameter requestId: The wire id of the request.
    func replayRequestDidStart(_ requestId: RequestId) {
        guard isReplaying, let finished = replayRequests.didStart(requestId) else { return }
        endReplay(succeeded: finished == .succeeded)
    }

    /// Ends each tap and the running replay when the connection ended the
    /// subscription. No marker can arrive after the end, so the replay ends
    /// as a failure.
    ///
    /// A cancelled task ends the loop as well. The close and a replaced
    /// subscription cancel the task, and neither must end the taps here: the
    /// close ends them itself, and a replaced subscription keeps them open.
    private func subscriptionDidEnd() {
        guard !Task.isCancelled else { return }
        streamTask = nil
        endRunningReplayAsFailure()
        finishUpdateTaps()
    }

    // MARK: - Replay

    /// Marks the start of a `session/resume` request.
    ///
    /// Call this before the request goes out, with the `replayFrom` cursor of
    /// the request. The model clears ``notices``, because a notice is a live
    /// event of the earlier attachment and no replay gives it again. When the
    /// request asks for a replay and the model already has a transcript, the
    /// model also clears its transcript and its last-value state, because a
    /// replayed chunk appends again and would double the text.
    ///
    /// - Parameter replayFrom: The `replayFrom` field of the request that the
    ///   client sends, or `nil` for no replay.
    func beginReplay(replayFrom: ReplayFrom?) {
        clearNotices()
        if replayFrom != nil, !transcript.isEmpty {
            flushPendingChunks()
            resetTranscript()
        }
        replayRequests = ReplayRequests()
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
        replayRequests = ReplayRequests()
        defer { resumeReplayEndWaiters() }
        flushPendingChunks()
        guard succeeded, case .replaying(from: let replayFrom?) = phase else { return }
        history = .retained(replayFrom: replayFrom)
        if case .start = replayFrom {
            hasMissedUpdates = false
        }
    }

    /// Ends the running replay as a failure. When no replay runs, the call
    /// changes nothing.
    func endRunningReplayAsFailure() {
        guard isReplaying else { return }
        endReplay(succeeded: false)
    }

    /// Waits until the running replay ends.
    ///
    /// The marker of the `session/resume` request ends the replay, after the
    /// model applied each replayed update. The end of the subscription and
    /// the close also end it. A model with no attached subscription gets no
    /// marker, so the call then ends the replay as a failure at once. When
    /// no replay runs, the call returns at once.
    func waitForReplayEnd() async {
        guard isReplaying else { return }
        guard streamTask != nil else {
            endRunningReplayAsFailure()
            return
        }
        await withCheckedContinuation { waiter in
            replayEndWaiters.append(waiter)
        }
    }

    /// Resumes each caller that waits for the end of the replay.
    private func resumeReplayEndWaiters() {
        let waiters = replayEndWaiters
        replayEndWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - Close

    /// Closes the model.
    ///
    /// The model ends the running replay as a failure, folds the buffered
    /// chunks, stops the task of the subscription, ends each ``updateTap()``
    /// stream, cancels each pending permission request and elicitation, and
    /// clears ``notices``. After the close, ``apply(_:)`` changes nothing.
    func markClosed() {
        endRunningReplayAsFailure()
        flushPendingChunks()
        streamTask?.cancel()
        streamTask = nil
        finishUpdateTaps()
        cancelAllPending()
        clearNotices()
        isClosed = true
    }
}
