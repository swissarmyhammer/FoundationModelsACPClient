import FoundationModelsACP
import FoundationModelsExtras
import Logging
import Tracing

// The session factory of `ConnectionModel`: the request that opens a new
// session, the request that resumes a session, and the request that closes
// an open session. Each method makes, registers, or closes the `SessionModel`
// of the session, so a host never subscribes to the updates of a session
// itself.
//
// Each request goes out through `sendRecordingAuth(_:through:)`: the client
// request span, the request metrics, and the W3C trace context in the `_meta`
// of the request of `ClientRequestSpan.send(_:parent:through:)`, and a
// `-32000` answer of the agent recorded in `authState`. Each resume also runs
// in one internal replay span, and the client span of its request is a child
// of that span.

extension ConnectionModel {
    // MARK: - New session

    /// Sends `session/new` as the caller made it, less each MCP server that
    /// the agent cannot get, and gives the model of the new session.
    ///
    /// The request sends only the MCP servers whose transport the agent
    /// advertises. The call logs one warning for each other server and does
    /// not throw, so the session opens with the servers that remain.
    ///
    /// The model subscribes to the updates of the session as soon as the
    /// response gives the session id. The first subscription gets each update
    /// that the connection kept for the session, so an update that the agent
    /// sends before its response is in the model. When the connection had to
    /// discard kept updates, the model has ``SessionModel/hasMissedUpdates``.
    ///
    /// The commands and the configuration options of the response seed the
    /// model, and the model goes into ``openSessions``. The MCP servers of the
    /// request go into ``SessionModel/mcpServers`` before the model folds an
    /// update. The `cwd` and the `additionalDirectories` of the request go
    /// into ``SessionModel/cwd`` and ``SessionModel/additionalDirectories``,
    /// so a host can resume the session later.
    ///
    /// When the connection closes, or a new connection takes its place,
    /// after the response arrives but before this call reads it, the model
    /// of the session is closed and does not go into ``openSessions``.
    ///
    /// - Parameter request: The new-session request.
    /// - Returns: The open model of the new session.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when the
    ///   request has additional directories and
    ///   ``canUseAdditionalDirectories`` is `false`, so the call sends
    ///   nothing; `ConnectionError.closed` when no connection is open, or
    ///   when the connection of the request is no longer the open
    ///   connection; the `RequestError` of the agent; or the error of the
    ///   connection. On an error, the model registers no session.
    public func newSession(_ request: NewSessionRequest) async throws -> SessionModel {
        try requireAdditionalDirectoriesCapability(for: request, method: ClientRequestSpan.Method.newSession)
        let connection = try openConnection()
        let sent = removingUnadvertisedMCPServers(from: request)
        // The hook of the wire marks the session as opening on the reader,
        // before the next frame. Each exit of this call ends that open, so a
        // request that waits for it gets the model, or cancel on a failure.
        let ticket = OpeningTicket()
        let opening = openingSessions
        defer {
            if let opened = ticket.recorded {
                opening.finish(opened)
            }
        }
        let response = try await sendRecordingAuth(sent) {
            try await connection.newSession($0) { answer in
                ticket.record(answer.sessionId)
                opening.markOpening(answer.sessionId)
            }
        }
        let session = makeSubscribedSessionModel(sessionId: response.sessionId, over: connection)
        // The list goes in before the stream task of the model can fold an
        // update, so a status update that the agent sends after the response
        // always finds it.
        session.setMCPServers(sent.mcpServers ?? [])
        session.setWorkspace(of: sent)
        session.seed(availableCommands: response.availableCommands, configOptions: response.configOptions)
        if let beforeRegisteringNewSession {
            await beforeRegisteringNewSession(response.sessionId)
        }
        try register(session, openedOver: connection)
        return session
    }

    /// Gives the open model of a session, and waits first when the session
    /// is opening.
    ///
    /// The router calls this for each request of the agent that names a
    /// session. When the `session/new` answer of the session arrived and its
    /// model is not registered yet, the call waits until the open ends, and
    /// then reads the open sessions again. For each other session that is not
    /// open, it returns `nil` at once.
    ///
    /// - Parameter sessionId: The id of the session.
    /// - Returns: The model, or `nil` when the session is not open.
    func openSession(waitingWhileOpening sessionId: SessionId) async -> SessionModel? {
        if let open = session(for: sessionId) {
            return open
        }
        await openingSessions.waitWhileOpening(sessionId)
        return session(for: sessionId)
    }

    // MARK: - Resume session

    /// Sends `session/resume` as the caller made it, less each MCP server
    /// that the agent cannot get, and gives the model of the session with
    /// the replay of the agent.
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
    /// the configuration options of the response then seed the model.
    ///
    /// A new model goes into ``openSessions`` before the request goes out, so
    /// it is open while its replay runs (``SessionModel/isReplaying`` is
    /// `true` then). Thus a permission request or an elicitation that the
    /// agent sends for the session during the resume, or at once after its
    /// answer, is pending on that model, and the router does not answer it
    /// with cancel.
    ///
    /// The request sends only the MCP servers whose transport the agent
    /// advertises, in the same way as ``newSession(_:)``. The servers that
    /// the request sends replace ``SessionModel/mcpServers`` before the
    /// request goes out, also for an open model, and each item starts again
    /// at ``MCPServerStatus/notReported``.
    ///
    /// After a successful response, the `cwd` and the
    /// `additionalDirectories` of the request replace
    /// ``SessionModel/cwd`` and ``SessionModel/additionalDirectories``, also
    /// for an open model. An omitted list gives an empty list, because the
    /// agent then activates no additional root.
    ///
    /// On a failure, the replay ends as a failure and the call throws. An
    /// open model stays open, gets back the MCP servers that it had before
    /// the call, and keeps its `cwd` and its additional directories. A new
    /// model goes out of ``openSessions`` and is closed. When the connection
    /// closes, or a new connection takes its place, before this call returns,
    /// a new model goes out of ``openSessions`` and is closed too, and the
    /// call throws `ConnectionError.closed`.
    ///
    /// The resumes of one session run one after the other. A call for a
    /// session whose earlier resume still runs waits until that resume
    /// returned or threw, and then runs. Thus it finds the model that the
    /// earlier resume registered, and its replay ends only at the marker of
    /// its own request. A failure or a cancel of the earlier resume does not
    /// end the replay of this call.
    ///
    /// - Parameter request: The resume-session request.
    /// - Returns: The open model of the session.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when
    ///   ``canResumeSessions`` is `false`, or when the request has additional
    ///   directories and ``canUseAdditionalDirectories`` is `false`, so the
    ///   call sends nothing; `ConnectionError.closed` when no connection is
    ///   open, or when the connection of the request is no longer the open
    ///   connection; the `RequestError` of the agent; or the error of the
    ///   connection.
    public func resumeSession(_ request: ResumeSessionRequest) async throws -> SessionModel {
        try requireCapability(canResumeSessions, method: ClientRequestSpan.Method.resumeSession)
        try requireAdditionalDirectoriesCapability(for: request, method: ClientRequestSpan.Method.resumeSession)
        return try await resumeTurns.run(for: request.sessionId) {
            try await resumeInTurn(request)
        }
    }

    /// Sends one `session/resume` request when no other resume of its session
    /// runs, and gives the model of the session with the replay.
    ///
    /// - Parameter request: The resume-session request.
    /// - Returns: The open model of the session.
    /// - Throws: `ConnectionError.closed` when no connection is open, or when
    ///   the connection of the request is no longer the open connection; the
    ///   `RequestError` of the agent; or the error of the connection.
    private func resumeInTurn(_ request: ResumeSessionRequest) async throws -> SessionModel {
        let connection = try openConnection()
        let sent = removingUnadvertisedMCPServers(from: request)
        if let open = self.session(for: sent.sessionId) {
            try await replay(sent, into: open, over: connection)
            return open
        }
        // The model goes into the open sessions BEFORE the request goes out.
        // The agent can ask a question of the session during the resume, or
        // at once after its answer, and the router then finds this model and
        // holds the question as pending.
        let session = makeSubscribedSessionModel(sessionId: sent.sessionId, over: connection)
        register(session)
        do {
            try await replay(sent, into: session, over: connection)
        } catch {
            unregisterAndClose(session)
            throw error
        }
        // The close of the connection closed and removed the model, or a new
        // connection took the place of this one.
        guard connection === self.connection, !session.isClosed else {
            unregisterAndClose(session)
            throw ConnectionError.closed
        }
        return session
    }

    /// Removes a model from ``openSessions`` when the list holds that same
    /// model, and closes it.
    ///
    /// The list can hold another model for the same session, for example the
    /// model of a resume on a later connection, and that model stays.
    ///
    /// - Parameter session: The model to remove and close.
    private func unregisterAndClose(_ session: SessionModel) {
        if self.session(for: session.sessionId) === session {
            unregister(session.sessionId)
        }
        session.markClosed()
    }

    /// Sends one `session/resume` request and runs its replay in a session
    /// model, in one replay span.
    ///
    /// The span has the name ``ACPClientTelemetry/SpanName/replay`` and the
    /// kind `.internal`. The client span of the request opens in it, so that
    /// span is its child. Rule 4: the span holds the session id, the
    /// ``ACPClientTelemetry/ReplayFromValue`` of the cursor, and the number
    /// of replayed updates, on each exit path. A refused request, and a
    /// replay that ends as a failure, give the error status. The span never
    /// records the error object.
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
        try await TracedCall.run(
            ACPClientTelemetry.SpanName.replay,
            ofKind: .internal,
            logger: Logger(label: ACPClientTelemetry.logLabel),
            attributes: { Self.setReplayAttributes(&$0, of: request) },
            metadata: [ACPClientTelemetry.LogMetadataKey.sessionID: "\(request.sessionId.rawValue)"]
        ) { span in
            defer {
                span.attributes[ACPClientTelemetry.AttributeKey.replayUpdateCount] = session.replayedUpdateCount
            }
            let succeeded = try await runReplay(request, into: session, over: connection)
            if !succeeded {
                span.setStatus(SpanStatus(code: .error))
            }
        }
    }

    /// Sets the attributes that a replay span holds from its start: the
    /// session id and the value of the cursor.
    ///
    /// - Parameters:
    ///   - attributes: The attributes of the span.
    ///   - request: The resume-session request.
    private static func setReplayAttributes(_ attributes: inout SpanAttributes, of request: ResumeSessionRequest) {
        attributes[ACPClientTelemetry.AttributeKey.sessionID] = request.sessionId.rawValue
        attributes[ACPClientTelemetry.AttributeKey.replayFrom] = replayFromValue(of: request.replayFrom)
    }

    /// Gives the telemetry value of a replay cursor.
    ///
    /// Rule 4: the value comes from a small, fixed set. It is never the type
    /// of a cursor that this schema revision does not know.
    ///
    /// - Parameter replayFrom: The `replayFrom` field of the request.
    /// - Returns: A value of ``ACPClientTelemetry/ReplayFromValue``.
    private static func replayFromValue(of replayFrom: ReplayFrom?) -> String {
        switch replayFrom {
        case nil: ACPClientTelemetry.ReplayFromValue.none
        case .start: ACPClientTelemetry.ReplayFromValue.start
        case .unknown: ACPClientTelemetry.ReplayFromValue.other
        }
    }

    /// Sends one `session/resume` request and runs its replay in a session
    /// model.
    ///
    /// The model must already be attached to a subscription of the session.
    /// The call returns after the model read the marker of the request, so
    /// the model then holds each replayed update.
    ///
    /// Only a successful response sets the `cwd` and the additional
    /// directories of the model, so a failure keeps the earlier values.
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
    /// - Returns: `true` when the replay ended with success, and `false` when
    ///   it ended as a failure after a successful response, for example
    ///   because the subscription ended before the marker.
    /// - Throws: The `RequestError` of the agent, or the error of the
    ///   connection. The replay then ended as a failure.
    private func runReplay(
        _ request: ResumeSessionRequest,
        into session: SessionModel,
        over connection: ClientSideConnection
    ) async throws -> Bool {
        // The agent sends the status of its MCP servers after the response,
        // so the list of the request must be in the model before the request
        // goes out. A list set after the response could erase those statuses.
        let mcpServersBeforeResume = session.mcpServers
        session.beginReplay(replayFrom: request.replayFrom)
        session.setMCPServers(request.mcpServers ?? [])
        let resumeStarts = watchResumeStarts(of: connection, for: session)
        defer { resumeStarts.cancel() }
        let response: ResumeSessionResponse
        do {
            response = try await sendRecordingAuth(request) { try await connection.resumeSession($0) }
        } catch {
            session.mcpServers = mcpServersBeforeResume
            await endReplay(of: session, afterFailure: error)
            throw error
        }
        let succeeded = await session.waitForReplayEnd()
        session.setWorkspace(of: request)
        session.seed(availableCommands: response.availableCommands, configOptions: response.configOptions)
        return succeeded
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
        // The request failed, so the replay is a failure whatever its end
        // gives.
        _ = await session.waitForReplayEnd()
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
            requestSender: ConnectionSessionRequestSender(connection: connection) { [weak self] error in
                self?.recordAuthRequired(ifThrownBy: error, over: connection)
            }
        )
        session.attach(subscription)
        return session
    }

    // MARK: - MCP servers

    /// Gives a copy of a request that sends only the MCP servers that the
    /// agent can get, and logs one warning for each server that the copy
    /// does not send.
    ///
    /// ``newSession(_:)`` and ``resumeSession(_:)`` send this copy. Each
    /// other field of the copy is as the caller made it.
    ///
    /// - Parameter request: The request as the caller made it.
    /// - Returns: The copy of `request`, with the servers whose transport
    ///   the agent advertises, in request order.
    func removingUnadvertisedMCPServers<Request: MCPServerListRequest>(from request: Request) -> Request {
        var sent = request
        sent.mcpServers = advertisedMCPServersWarningOfEachRemoved(in: request.mcpServers)
        return sent
    }

    /// Gives the MCP servers of a request that the agent can get, and logs
    /// one warning for each server that the request does not send.
    ///
    /// The session opens with the servers that remain, so a removed server
    /// is not an error.
    ///
    /// - Parameter servers: The `mcpServers` field of the request.
    /// - Returns: The servers whose transport the agent advertises, in
    ///   request order, or `nil` when `servers` is `nil`.
    private func advertisedMCPServersWarningOfEachRemoved(in servers: [MCPServer]?) -> [MCPServer]? {
        for server in servers ?? [] where !advertisesTransport(of: server) {
            connectionLogger.log(Self.removedMCPServerWarning(for: server))
        }
        return advertisedMCPServers(in: servers)
    }

    /// Gives the warning for an MCP server that a request does not send,
    /// because the agent does not advertise its transport.
    ///
    /// - Parameter server: The removed server.
    /// - Returns: The warning, with the name and the transport of the server.
    private static func removedMCPServerWarning(for server: MCPServer) -> String {
        let label = server.nameAndTransport
        let name = label.name.map { "the MCP server \"\($0)\"" } ?? "an MCP server with no name"
        return "ConnectionModel: removed \(name) of the \(label.transport) transport from the request, "
            + "because the agent does not advertise that transport"
    }

    // MARK: - Additional directories

    /// Throws when a request has additional directories and the agent does
    /// not advertise `session.additionalDirectories`.
    ///
    /// ``newSession(_:)`` and ``resumeSession(_:)`` call this before they
    /// send the request, so a request that the agent cannot read sends
    /// nothing. A request with an omitted or empty list needs no capability.
    ///
    /// - Parameters:
    ///   - request: The request as the caller made it.
    ///   - method: The ACP wire method of the request, for the error.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when
    ///   `request` has additional directories and
    ///   ``canUseAdditionalDirectories`` is `false`.
    private func requireAdditionalDirectoriesCapability(
        for request: some SessionWorkspaceRequest,
        method: String
    ) throws {
        guard request.hasAdditionalDirectories else { return }
        try requireCapability(canUseAdditionalDirectories, method: method)
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
        let connection = try openConnection()
        _ = try await sendRecordingAuth(CloseSessionRequest(sessionId: session.sessionId)) {
            try await connection.closeSession($0)
        }
        unregister(session.sessionId)
        session.markClosed()
    }
}

/// A request that sends a list of MCP servers to the agent.
///
/// ``ConnectionModel/removingUnadvertisedMCPServers(from:)`` filters the
/// list of each request of this kind, so the rule for the servers that go
/// out is in one location.
protocol MCPServerListRequest {
    /// The MCP servers that the request sends, or `nil` when the request
    /// sends no list.
    var mcpServers: [MCPServer]? { get set }
}

extension NewSessionRequest: MCPServerListRequest {}

extension ResumeSessionRequest: MCPServerListRequest {}

/// A request that sets the working directory and the additional workspace
/// roots of a session.
///
/// ``ConnectionModel`` checks the additional directories of each request of
/// this kind against the capability of the agent, and
/// ``SessionModel/setWorkspace(of:)`` keeps both values, so a host can
/// resume the session later.
protocol SessionWorkspaceRequest {
    /// The working directory of the session.
    var cwd: AbsolutePath { get }

    /// The additional workspace roots of the session, or `nil` when the
    /// request sends no list.
    var additionalDirectories: [AbsolutePath]? { get }
}

extension SessionWorkspaceRequest {
    /// Tells whether the request sends at least one additional directory.
    /// An omitted list and an empty list activate no additional root.
    var hasAdditionalDirectories: Bool {
        !(additionalDirectories ?? []).isEmpty
    }
}

extension NewSessionRequest: SessionWorkspaceRequest {}

extension ResumeSessionRequest: SessionWorkspaceRequest {}

extension MCPServer {
    /// The name and the wire transport of the server, for a log message.
    ///
    /// A server with a transport that this schema revision does not know has
    /// a name only when its payload has a string `name` member.
    fileprivate var nameAndTransport: (name: String?, transport: String) {
        switch self {
        case .http(let configuration):
            (configuration.name, MCPServerTransport.http.rawValue)
        case .stdio(let configuration):
            (configuration.name, MCPServerTransport.stdio.rawValue)
        case .unknown(let transport, let payload):
            (payload.stringMember(Self.nameMember), transport)
        }
    }

    /// The name of the member that holds the name of a server in its
    /// payload.
    private static let nameMember = "name"
}
