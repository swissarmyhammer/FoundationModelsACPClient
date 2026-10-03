import FoundationModelsACP

// The session factory of `ConnectionModel`: the request that opens a new
// session, and the request that closes an open session. Each method makes,
// registers, or closes the `SessionModel` of the session, so a host never
// subscribes to the updates of a session itself.

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
        let subscription = connection.subscribe(to: response.sessionId)
        let session = makeSessionModel(
            sessionId: response.sessionId,
            requestSender: ConnectionSessionRequestSender(connection: connection)
        )
        session.attach(subscription)
        session.seed(availableCommands: response.availableCommands, configOptions: response.configOptions)
        try register(session, openedOver: connection)
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
