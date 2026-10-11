import FoundationModelsACP

/// The `Client` that a ``ConnectionModel`` serves.
///
/// The router gives each request of the agent to the model that owns it:
///
/// - A permission request goes to the open ``SessionModel`` of its session.
/// - A session-scoped elicitation goes to the open ``SessionModel`` of its
///   session. A request-scoped elicitation goes to the ``ConnectionModel``,
///   which holds it while the client request that it names is in flight.
/// - An `elicitation/complete` goes to the session model that holds that
///   elicitation, or else to the request-scoped elicitations of the
///   ``ConnectionModel``.
///
/// The router answers at once when no model can take a request: a permission
/// request gets the `cancelled` outcome, and an elicitation gets the `cancel`
/// action. These are the answers of the spec for a request that nobody
/// decided, so the agent never waits for ever. A request for a session that is
/// not open, a request-scoped elicitation for a client request that is not in
/// flight, and an elicitation of a mode that the client does not know, also
/// log one warning.
///
/// The router ignores each `session/update`: each ``SessionModel`` reads its
/// updates from its own subscription.
///
/// ## Telemetry
///
/// The router handles each permission request, each elicitation and each
/// `elicitation/complete` in one server span of ``AgentRequestSpan``. The span
/// ends after the user answers, so a trace shows how long the agent waited for
/// the user, and it joins the trace of the agent through the `_meta` of the
/// message. The span holds ``ACPClientTelemetry/AttributeKey/routed`` and
/// ``ACPClientTelemetry/AttributeKey/outcome``. Rule 4: no attribute holds a
/// title, a description, an option name, a message, a URL or form content. A
/// `session/update` gets no span, because a span for each update makes too
/// many spans.
struct ModelClient: Client {
    /// The text that starts each warning of the router.
    private static let logPrefix = "ModelClient: "

    /// The model that this router serves. The model holds the connection, and
    /// the connection holds this router, so the reference is weak. When the
    /// model is gone, no session is open.
    private weak let model: ConnectionModel?

    /// The diagnostic sink of the connection; never stdout.
    private let logger: ACPLogger

    /// Makes the router of a model.
    ///
    /// - Parameters:
    ///   - model: The model that this router serves.
    ///   - logger: The diagnostic sink of the connection; never stdout.
    init(model: ConnectionModel, logger: ACPLogger) {
        self.model = model
        self.logger = logger
    }

    /// Ignores the update. The session model reads it from its subscription.
    ///
    /// - Parameter notification: The session-update notification.
    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    /// Gives the permission request to the open model of its session, and
    /// waits for the user's decision.
    ///
    /// After the decision, and before this handler returns, the router asks
    /// the connection to give the "written" signal of the request when it
    /// wrote the response, or when it will never write it. Thus
    /// `SessionModel.selectPermission(_:option:)` returns only after the
    /// response is on the wire.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The user's decision, or the `cancelled` outcome when the
    ///   session is not open.
    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        try await traceRequest(
            ClientRequestSpan.Method.requestPermission,
            sessionId: params.sessionId,
            meta: params.meta,
            fallback: PendingPermissionRequest.cancelledResponse,
            outcome: { Self.permissionOutcome(of: $0.outcome) },
            route: { await routePermission(params) }
        )
    }

    /// Gives the elicitation to the model of its scope, and waits for the
    /// user's response.
    ///
    /// - Parameter params: The elicitation request.
    /// - Returns: The user's response, or the `cancel` action when no model
    ///   can take the elicitation.
    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        try await traceRequest(
            ClientRequestSpan.Method.createElicitation,
            sessionId: Self.sessionId(of: params),
            meta: params.meta,
            fallback: ElicitationResponseWire.cancelResponse,
            outcome: Self.elicitationOutcome(of:),
            route: { await routeElicitation(params) }
        )
    }

    /// Gives the notice to the model that holds the elicitation it names.
    ///
    /// - Parameter notification: The completion notification.
    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        do {
            try await traceRequest(
                ClientRequestSpan.Method.completeElicitation,
                sessionId: nil,
                meta: notification.meta,
                fallback: false,
                outcome: { $0 ? ACPClientTelemetry.OutcomeValue.matched : ACPClientTelemetry.OutcomeValue.unmatched },
                route: { await model?.completeElicitation(elicitationId: notification.elicitationId) }
            )
        } catch {
            // `AgentRequestSpan.run` throws only the error of its body, and
            // this body throws nothing.
            assertionFailure("The span of an elicitation/complete threw \(type(of: error)).")
            logger.log(Self.logPrefix + "the span of an elicitation/complete threw \(type(of: error))")
        }
    }

    /// Handles one message of the agent in a server span, and records how the
    /// router answered it.
    ///
    /// The span ends after `route` returns, so its duration includes the wait
    /// for the user.
    ///
    /// - Parameters:
    ///   - method: The ACP wire method of the message.
    ///   - sessionId: The session that the message names, or `nil`.
    ///   - meta: The `_meta` of the message, as the agent sent it.
    ///   - fallback: The answer when no model takes the message.
    ///   - outcome: Gives the ``ACPClientTelemetry/OutcomeValue`` of an
    ///     answer.
    ///   - route: Gives the message to the model that takes it, and gives the
    ///     answer of that model, or `nil` when no model takes the message.
    /// - Returns: The answer of the model, or `fallback`.
    /// - Throws: The error of the span, which only rethrows the error of its
    ///   body.
    @discardableResult
    private func traceRequest<Response>(
        _ method: String,
        sessionId: SessionId?,
        meta: JSONValue?,
        fallback: Response,
        outcome: (Response) -> String,
        route: () async -> Response?
    ) async throws -> Response {
        try await AgentRequestSpan.run(method: method, sessionId: sessionId, meta: meta) { span in
            let routed = await route()
            let response = routed ?? fallback
            span.attributes[ACPClientTelemetry.AttributeKey.routed] = routed != nil
            span.attributes[ACPClientTelemetry.AttributeKey.outcome] = outcome(response)
            return response
        }
    }

    /// Gives the permission request to the open model of its session, and
    /// waits for the user's decision.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The user's decision, or `nil` when the session is not open.
    private func routePermission(_ params: RequestPermissionRequest) async -> RequestPermissionResponse? {
        guard let model, let session = await model.session(for: params.sessionId) else {
            let warning = Self.closedSessionWarning(
                answer: "cancelled",
                request: "a permission request",
                sessionId: params.sessionId
            )
            logger.log(warning)
            return nil
        }
        return await session.awaitPermissionDecision(for: params) { signal in
            model.signalAfterCurrentResponse(signal)
        }
    }

    /// Gives the elicitation to the model of its scope, and waits for the
    /// user's response.
    ///
    /// - Parameter params: The elicitation request.
    /// - Returns: The user's response, or `nil` when no model can take the
    ///   elicitation.
    private func routeElicitation(_ params: CreateElicitationRequest) async -> CreateElicitationResponse? {
        switch params.elicitationScope {
        case .session(let scope):
            return await awaitSessionElicitation(params, sessionId: scope.sessionId)
        case .request(let scope):
            return await awaitRequestElicitation(params, requestId: scope.requestId)
        case .unknownMode(let name):
            logger.log(Self.logPrefix + "answered cancel to an elicitation of the unknown mode \"\(name)\"")
            return nil
        }
    }

    /// Gives a session-scoped elicitation to the open model of its session,
    /// and waits for the user's response.
    ///
    /// - Parameters:
    ///   - request: The session-scoped elicitation.
    ///   - sessionId: The session of the elicitation.
    /// - Returns: The user's response, or `nil` when the session is not open.
    private func awaitSessionElicitation(
        _ request: CreateElicitationRequest,
        sessionId: SessionId
    ) async -> CreateElicitationResponse? {
        guard let session = await model?.session(for: sessionId) else {
            logger.log(Self.closedSessionWarning(answer: "cancel", request: "an elicitation", sessionId: sessionId))
            return nil
        }
        return await session.awaitElicitation(request)
    }

    /// Gives a request-scoped elicitation to the connection model, and waits
    /// for the user's response.
    ///
    /// - Parameters:
    ///   - request: The request-scoped elicitation.
    ///   - requestId: The wire id of the client request that it names.
    /// - Returns: The user's response, or `nil` when no client request with
    ///   that id is in flight.
    private func awaitRequestElicitation(
        _ request: CreateElicitationRequest,
        requestId: RequestId
    ) async -> CreateElicitationResponse? {
        guard let response = await model?.awaitRequestScopedElicitation(request, requestId: requestId) else {
            logger.log(
                Self.logPrefix
                    + "answered cancel to a request-scoped elicitation, because the request \(requestId) is not in flight"
            )
            return nil
        }
        return response
    }

    /// Gives the session of a session-scoped elicitation.
    ///
    /// - Parameter request: The elicitation request.
    /// - Returns: The session of the scope, or `nil` for a request-scoped
    ///   elicitation and for a mode that the client does not know.
    private static func sessionId(of request: CreateElicitationRequest) -> SessionId? {
        guard case .session(let scope) = request.elicitationScope else { return nil }
        return scope.sessionId
    }

    /// Makes the warning for a request whose session is not open.
    ///
    /// - Parameters:
    ///   - answer: The answer that the router gave, as words.
    ///   - request: The kind of the request, as words.
    ///   - sessionId: The session that the request names.
    /// - Returns: The warning.
    private static func closedSessionWarning(answer: String, request: String, sessionId: SessionId) -> String {
        logPrefix + "answered \(answer) to \(request), because the session \"\(sessionId.rawValue)\" is not open"
    }
}

// MARK: - Span outcomes

extension ModelClient {
    /// The outcome value of each elicitation action that the spec names, keyed
    /// by the action.
    private static let elicitationActionOutcomes: [String: String] = [
        ElicitationResponseWire.acceptAction: ACPClientTelemetry.OutcomeValue.accept,
        ElicitationResponseWire.declineAction: ACPClientTelemetry.OutcomeValue.decline,
        ElicitationResponseWire.cancelAction: ACPClientTelemetry.OutcomeValue.cancel,
    ]

    /// Gives the span outcome of the answer to a permission request.
    ///
    /// - Parameter outcome: The outcome of the answer.
    /// - Returns: ``ACPClientTelemetry/OutcomeValue/selected`` or
    ///   ``ACPClientTelemetry/OutcomeValue/cancelled``, or
    ///   ``ACPClientTelemetry/OutcomeValue/other`` for an outcome that this
    ///   schema revision does not know. The value is never a string of the
    ///   wire.
    static func permissionOutcome(of outcome: RequestPermissionOutcome) -> String {
        switch outcome {
        case .selected: ACPClientTelemetry.OutcomeValue.selected
        case .cancelled: ACPClientTelemetry.OutcomeValue.cancelled
        case .unknown: ACPClientTelemetry.OutcomeValue.other
        }
    }

    /// Gives the span outcome of the answer to an elicitation.
    ///
    /// The response is raw JSON, so the function reads its `action` member and
    /// finds the value of that action in a fixed table. Rule 4: it never copies
    /// the raw string into the outcome.
    ///
    /// - Parameter response: The answer to the elicitation.
    /// - Returns: ``ACPClientTelemetry/OutcomeValue/accept``,
    ///   ``ACPClientTelemetry/OutcomeValue/decline`` or
    ///   ``ACPClientTelemetry/OutcomeValue/cancel``, or
    ///   ``ACPClientTelemetry/OutcomeValue/other`` for each other action and
    ///   for a response with no `action` member.
    static func elicitationOutcome(of response: CreateElicitationResponse) -> String {
        guard case .object(let members) = response,
            case .string(let action)? = members[ElicitationResponseWire.actionKey],
            let outcome = elicitationActionOutcomes[action]
        else { return ACPClientTelemetry.OutcomeValue.other }
        return outcome
    }
}
