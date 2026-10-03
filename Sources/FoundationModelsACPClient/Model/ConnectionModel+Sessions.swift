import FoundationModelsACP

// The session factory of `ConnectionModel`: the request that opens a new
// session, the request that resumes a session, and the request that closes
// an open session. Each method makes, registers, or closes the `SessionModel`
// of the session, so a host never subscribes to the updates of a session
// itself.

extension ConnectionModel {
    // MARK: - New session

    /// Sends `session/new` as the caller made it, and gives the model of the
    /// new session.
    ///
    /// The model subscribes to the updates of the session as soon as the
    /// response gives the session id. The first subscription gets each update
    /// that the connection kept for the session, so an update that the agent
    /// sends before its response is in the model. When the connection had to
    /// discard kept updates, the model has ``SessionModel/hasMissedUpdates``.
    ///
    /// The commands and the configuration options of the response seed the
    /// model, and the model goes into ``openSessions``.
    ///
    /// When the connection closes, or a new connection takes its place,
    /// after the response arrives but before this call reads it, the model
    /// of the session is closed and does not go into ``openSessions``.
    ///
    /// - Parameter request: The new-session request.
    /// - Returns: The open model of the new session.
    /// - Throws: `ConnectionError.closed` when no connection is open, or when
    ///   the connection of the request is no longer the open connection; the
    ///   `RequestError` of the agent; or the error of the connection. On an
    ///   error, the model registers no session.
    public func newSession(_ request: NewSessionRequest) async throws -> SessionModel {
        let connection = try openConnection()
        let response = try await connection.newSession(request)
        let session = makeSubscribedSessionModel(sessionId: response.sessionId, over: connection)
        session.seed(availableCommands: response.availableCommands, configOptions: response.configOptions)
        try register(session, openedOver: connection)
        return session
    }

    // MARK: - Resume session

    /// Sends `session/resume` as the caller made it, and gives the model of
    /// the session with the replay of the agent.
    ///
    /// For a session that is open, the call reuses its model and its
    /// subscription, and gives the same instance. For another session, the
    /// call makes a model and subscribes to the session BEFORE the request
    /// goes out, so the subscription gets each replayed update.
    ///
    /// ``SessionModel/beginReplay(replayFrom:)`` starts the replay before the
    /// request goes out. A replay of an open model clears its transcript
    /// first, so a replayed chunk does not double the text. The connection
    /// puts the marker of the request in the stream of the session after the
    /// last replayed update, and the model ends the replay when it reads that
    /// marker. Thus, when this call returns, the model holds the whole replay
    /// and ``SessionModel/isReplaying`` is `false`. A successful replay from
    /// the start clears ``SessionModel/hasMissedUpdates``. The commands and
    /// the configuration options of the response then seed the model, and a
    /// new model goes into ``openSessions``.
    ///
    /// On a failure, the replay ends as a failure and the call throws. An
    /// open model stays open. A new model is closed and does not go into
    /// ``openSessions``. When the connection closes, or a new connection
    /// takes its place, after the response arrives but before this call reads
    /// it, a new model is closed too.
    ///
    /// - Parameter request: The resume-session request.
    /// - Returns: The open model of the session.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when
    ///   ``canResumeSessions`` is `false`, so the call sends nothing;
    ///   `ConnectionError.closed` when no connection is open, or when the
    ///   connection of the request is no longer the open connection; the
    ///   `RequestError` of the agent; or the error of the connection.
    public func resumeSession(_ request: ResumeSessionRequest) async throws -> SessionModel {
        try requireCapability(canResumeSessions, method: ClientRequestSpan.Method.resumeSession)
        let connection = try openConnection()
        if let open = openSessions[request.sessionId] {
            try await replay(request, into: open, over: connection)
            return open
        }
        let session = makeSubscribedSessionModel(sessionId: request.sessionId, over: connection)
        do {
            try await replay(request, into: session, over: connection)
        } catch {
            session.markClosed()
            throw error
        }
        try register(session, openedOver: connection)
        return session
    }

    /// Sends one `session/resume` request and runs its replay in a session
    /// model.
    ///
    /// The model must already be attached to a subscription of the session.
    /// The call returns after the model read the marker of the request, so
    /// the model then holds each replayed update.
    ///
    /// The model learns the wire id of the request from the outgoing-request
    /// events, and only the marker with that id ends the replay. The marker
    /// of an earlier `session/resume` request that its caller cancelled can
    /// still be unread in the stream of the session, and it must not end
    /// this replay.
    ///
    /// - Parameters:
    ///   - request: The resume-session request.
    ///   - session: The model of the session, attached to its subscription.
    ///   - connection: The connection that sends the request.
    /// - Throws: The `RequestError` of the agent, or the error of the
    ///   connection. The replay then ended as a failure.
    private func replay(
        _ request: ResumeSessionRequest,
        into session: SessionModel,
        over connection: ClientSideConnection
    ) async throws {
        session.beginReplay(replayFrom: request.replayFrom)
        let resumeStarts = watchResumeStarts(of: connection, for: session)
        defer { resumeStarts.cancel() }
        let response: ResumeSessionResponse
        do {
            response = try await connection.resumeSession(request)
        } catch {
            await endReplay(of: session, afterFailure: error)
            throw error
        }
        await session.waitForReplayEnd()
        session.seed(availableCommands: response.availableCommands, configOptions: response.configOptions)
    }

    /// Starts the task that gives a session model the wire id of each
    /// `session/resume` request that the connection starts.
    ///
    /// The subscription is made before this method returns, so the task sees
    /// the start of the request that the caller sends next. The events name
    /// no session, so the model also gets the ids of the resumes of other
    /// sessions; their markers never come in the stream of this session. A
    /// request that finished before the subscription gives no start event, so
    /// its marker never ends the replay of the model.
    ///
    /// - Parameters:
    ///   - connection: The connection whose requests to watch.
    ///   - session: The model whose replay runs.
    /// - Returns: The task that reads the events. Cancel it when the replay
    ///   ended.
    private func watchResumeStarts(of connection: ClientSideConnection, for session: SessionModel) -> Task<Void, Never> {
        let events = connection.subscribeToOutgoingRequests()
        return Task { [weak session] in
            for await case .started(let requestId, ClientRequestSpan.Method.resumeSession) in events {
                session?.replayRequestDidStart(requestId)
            }
        }
    }

    /// Ends the replay of a `session/resume` request that failed.
    ///
    /// The connection gives a failed marker to each request that went out,
    /// at the wire position of its failure, and a closed connection ends the
    /// stream. The model then ends the replay at that marker or at that end,
    /// after each replayed update that came before the failure. A request
    /// that never went out gives no marker: the encoding of the request
    /// failed, or the task was cancelled before the start. For these two
    /// errors, the replay ends at once. When a cancelled request did go out,
    /// its late marker cannot end a later replay, because the request did not
    /// start during that replay.
    ///
    /// - Parameters:
    ///   - session: The model of the session.
    ///   - error: The error of the request.
    private func endReplay(of session: SessionModel, afterFailure error: any Error) async {
        guard !(error is CancellationError || error is EncodingError) else {
            session.endRunningReplayAsFailure()
            return
        }
        await session.waitForReplayEnd()
    }

    /// Makes the model of a session, attached to a new subscription of the
    /// session on a connection.
    ///
    /// The model sends the requests of the session over the same connection.
    /// The first subscription to a session gets each update that the
    /// connection kept for it, and the overflow mark.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session.
    ///   - connection: The connection of the session.
    /// - Returns: The model, not yet in ``openSessions``.
    private func makeSubscribedSessionModel(sessionId: SessionId, over connection: ClientSideConnection) -> SessionModel {
        let subscription = connection.subscribe(to: sessionId)
        let session = makeSessionModel(
            sessionId: sessionId,
            requestSender: ConnectionSessionRequestSender(connection: connection)
        )
        session.attach(subscription)
        return session
    }

    // MARK: - Registration

    /// Adds the model of a session that a request opened to
    /// ``openSessions``, when the connection of that request is still the
    /// open connection.
    ///
    /// The request suspends the model while it waits for the agent. In that
    /// time the connection can close, which closes each open session model,
    /// or a new connection can take its place. A model registered after that
    /// would stay open for a connection that no longer exists, so this method
    /// closes it instead.
    ///
    /// - Parameters:
    ///   - session: The model of the session that the request opened.
    ///   - connection: The connection that sent the request.
    /// - Throws: `ConnectionError.closed` when `connection` is no longer the
    ///   open connection. The model is then closed and not registered.
    private func register(_ session: SessionModel, openedOver connection: ClientSideConnection) throws {
        guard connection === self.connection else {
            session.markClosed()
            throw ConnectionError.closed
        }
        register(session)
    }

    // MARK: - Close

    /// Sends `session/close` for a session, and closes its model.
    ///
    /// When the agent accepts the close, the model goes out of
    /// ``openSessions`` and gets ``SessionModel/isClosed``. The closed model
    /// keeps its transcript and its last-value state, so a view can still
    /// show them.
    ///
    /// When ``canCloseSessions`` is `false`, the call sends nothing and the
    /// model stays open. When the agent refuses the close, the model stays
    /// open too.
    ///
    /// - Parameter session: The model of the session to close.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when
    ///   ``canCloseSessions`` is `false`, `ConnectionError.closed` when no
    ///   connection is open, or the error of the agent or of the connection.
    public func close(_ session: SessionModel) async throws {
        try requireCapability(canCloseSessions, method: ClientRequestSpan.Method.closeSession)
        _ = try await openConnection().closeSession(CloseSessionRequest(sessionId: session.sessionId))
        unregister(session.sessionId)
        session.markClosed()
    }
}
