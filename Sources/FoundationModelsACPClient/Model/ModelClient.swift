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
        guard let model, let session = await model.session(for: params.sessionId) else {
            let warning = Self.closedSessionWarning(
                answer: "cancelled",
                request: "a permission request",
                sessionId: params.sessionId
            )
            logger.log(warning)
            return PendingPermissionRequest.cancelledResponse
        }
        return await session.awaitPermissionDecision(for: params) { signal in
            model.signalAfterCurrentResponse(signal)
        }
    }

    /// Gives the elicitation to the model of its scope, and waits for the
    /// user's response.
    ///
    /// - Parameter params: The elicitation request.
    /// - Returns: The user's response, or the `cancel` action when no model
    ///   can take the elicitation.
    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        switch params.elicitationScope {
        case .session(let scope):
            return await awaitSessionElicitation(params, sessionId: scope.sessionId)
        case .request(let scope):
            return await awaitRequestElicitation(params, requestId: scope.requestId)
        case .unknownMode(let name):
            logger.log(Self.logPrefix + "answered cancel to an elicitation of the unknown mode \"\(name)\"")
            return ElicitationResponseWire.cancelResponse
        }
    }

    /// Gives the notice to the model that holds the elicitation it names.
    ///
    /// - Parameter notification: The completion notification.
    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        await model?.completeElicitation(elicitationId: notification.elicitationId)
    }

    /// Gives a session-scoped elicitation to the open model of its session,
    /// and waits for the user's response.
    ///
    /// - Parameters:
    ///   - request: The session-scoped elicitation.
    ///   - sessionId: The session of the elicitation.
    /// - Returns: The user's response, or the `cancel` action when the session
    ///   is not open.
    private func awaitSessionElicitation(
        _ request: CreateElicitationRequest,
        sessionId: SessionId
    ) async -> CreateElicitationResponse {
        guard let session = await model?.session(for: sessionId) else {
            logger.log(Self.closedSessionWarning(answer: "cancel", request: "an elicitation", sessionId: sessionId))
            return ElicitationResponseWire.cancelResponse
        }
        return await session.awaitElicitation(request)
    }

    /// Gives a request-scoped elicitation to the connection model, and waits
    /// for the user's response.
    ///
    /// - Parameters:
    ///   - request: The request-scoped elicitation.
    ///   - requestId: The wire id of the client request that it names.
    /// - Returns: The user's response, or the `cancel` action when no client
    ///   request with that id is in flight.
    private func awaitRequestElicitation(
        _ request: CreateElicitationRequest,
        requestId: RequestId
    ) async -> CreateElicitationResponse {
        guard let response = await model?.awaitRequestScopedElicitation(request, requestId: requestId) else {
            logger.log(
                Self.logPrefix
                    + "answered cancel to a request-scoped elicitation, because the request \(requestId) is not in flight"
            )
            return ElicitationResponseWire.cancelResponse
        }
        return response
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
