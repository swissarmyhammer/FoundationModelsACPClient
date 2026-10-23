import FoundationModelsACP

/// What the ``GraphQLTunnelStubAgent`` does for each `_sah/graphql/subscribe`.
///
/// The agent sends each notification of the script before it answers the
/// subscribe request. The real tunnel can do the same, because it starts the
/// task of the subscription before it answers. Thus a client that routes the
/// subscription id only after the answer loses these notifications.
struct GraphQLSubscriptionScript: Sendable {
    /// The last message of the subscription.
    enum End: Sendable {
        /// The agent sends `_sah/graphql/complete`.
        case complete

        /// The agent sends `_sah/graphql/error` with these GraphQL errors.
        case error([JSONValue])

        /// The agent sends no end. The subscription stays open.
        case hold
    }

    /// The results that the agent sends in `_sah/graphql/next`, in order.
    var events: [SAH.GraphQL.ExecutionResult] = []

    /// The results that the agent sends in `_sah/graphql/next` with another
    /// subscription id, before the events of the subscription.
    var foreignEvents: [SAH.GraphQL.ExecutionResult] = []

    /// The last message of the subscription.
    var end: End = .hold

    /// The error that the subscribe request gets in place of its answer, or
    /// `nil` for the answer.
    var refusal: RequestError?
}

/// An agent that serves only the `_sah/graphql/*` methods of the GraphQL
/// tunnel, with fixed answers, and records each call.
///
/// The session methods of `Agent` answer method-not-found: the GraphQL tests
/// send no session request.
final class GraphQLTunnelStubAgent: Agent {
    /// The subscription id of the foreign events of a script. No client
    /// subscription has this id.
    static let foreignSubscriptionId = SAH.GraphQL.SubscriptionId(rawValue: "foreign-subscription")

    /// The connection back to the client.
    private let connection: AgentSideConnection

    /// The answer of each `_sah/graphql/execute`.
    private let executeResult: SAH.GraphQL.ExecutionResult

    /// The answer of each `_sah/graphql/endpoints`.
    private let endpointList: [SAH.GraphQL.Endpoint]

    /// What the agent does for each `_sah/graphql/subscribe`.
    private let subscription: GraphQLSubscriptionScript

    /// The params of each `_sah/graphql/execute`, in arrival order.
    let executeRequests = ThreadSafeBuffer<SAH.GraphQL.ExecuteRequest>()

    /// The params of each `_sah/graphql/subscribe`, in arrival order.
    let subscribeRequests = ThreadSafeBuffer<SAH.GraphQL.SubscribeRequest>()

    /// The subscription id of each `_sah/graphql/unsubscribe`, in arrival
    /// order.
    let unsubscribes = ThreadSafeBuffer<SAH.GraphQL.SubscriptionId>()

    /// Makes the agent.
    ///
    /// - Parameters:
    ///   - connection: The connection back to the client.
    ///   - executeResult: The answer of each `_sah/graphql/execute`.
    ///   - endpointList: The answer of each `_sah/graphql/endpoints`.
    ///   - subscription: What the agent does for each
    ///     `_sah/graphql/subscribe`.
    init(
        connection: AgentSideConnection,
        executeResult: SAH.GraphQL.ExecutionResult = SAH.GraphQL.ExecutionResult(),
        endpointList: [SAH.GraphQL.Endpoint] = [],
        subscription: GraphQLSubscriptionScript = GraphQLSubscriptionScript()
    ) {
        self.connection = connection
        self.executeResult = executeResult
        self.endpointList = endpointList
        self.subscription = subscription
    }

    var extensionHandlers: ExtensionHandlers {
        var handlers = ExtensionHandlers()
        handlers.registerMethod(SAH.GraphQL.Method.execute, params: SAH.GraphQL.ExecuteRequest.self) { request in
            self.executeRequests.append(request)
            return self.executeResult
        }
        handlers.registerMethod(SAH.GraphQL.Method.endpoints, params: SAH.GraphQL.EndpointsRequest.self) { _ in
            SAH.GraphQL.EndpointsResponse(endpoints: self.endpointList)
        }
        handlers.registerMethod(SAH.GraphQL.Method.subscribe, params: SAH.GraphQL.SubscribeRequest.self) { request in
            try await self.subscribe(request)
        }
        handlers.registerNotification(
            SAH.GraphQL.Method.unsubscribe, params: SAH.GraphQL.UnsubscribeNotification.self
        ) { notification in
            self.unsubscribes.append(notification.subscriptionId)
        }
        return handlers
    }

    /// Serves one `_sah/graphql/subscribe`: records it, sends the
    /// notifications of the script, and answers.
    ///
    /// - Parameter request: The params of the call.
    /// - Returns: The answer that tells that the subscription started.
    /// - Throws: The refusal of the script, or an error of the wire.
    private func subscribe(_ request: SAH.GraphQL.SubscribeRequest) async throws -> SAH.GraphQL.SubscribeResponse {
        subscribeRequests.append(request)
        if let refusal = subscription.refusal {
            throw refusal
        }
        for event in subscription.foreignEvents {
            try await sendNext(event, for: Self.foreignSubscriptionId)
        }
        for event in subscription.events {
            try await sendNext(event, for: request.subscriptionId)
        }
        try await sendEnd(of: request.subscriptionId)
        return SAH.GraphQL.SubscribeResponse()
    }

    /// Sends one `_sah/graphql/next`.
    ///
    /// - Parameters:
    ///   - event: The result.
    ///   - id: The subscription id of the notification.
    /// - Throws: An error of the wire.
    private func sendNext(_ event: SAH.GraphQL.ExecutionResult, for id: SAH.GraphQL.SubscriptionId) async throws {
        try await connection.sendExtensionNotification(
            SAH.GraphQL.Method.next, SAH.GraphQL.NextNotification(subscriptionId: id, payload: event))
    }

    /// Sends the end of the script, when it has one.
    ///
    /// - Parameter id: The subscription id.
    /// - Throws: An error of the wire.
    private func sendEnd(of id: SAH.GraphQL.SubscriptionId) async throws {
        switch subscription.end {
        case .complete:
            try await connection.sendExtensionNotification(
                SAH.GraphQL.Method.complete, SAH.GraphQL.CompleteNotification(subscriptionId: id))
        case .error(let errors):
            try await connection.sendExtensionNotification(
                SAH.GraphQL.Method.error, SAH.GraphQL.ErrorNotification(subscriptionId: id, payload: errors))
        case .hold:
            break
        }
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        throw RequestError.methodNotFound("initialize")
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        throw RequestError.methodNotFound("session/new")
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        throw RequestError.methodNotFound("session/list")
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        throw RequestError.methodNotFound("session/resume")
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        throw RequestError.methodNotFound("session/close")
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        throw RequestError.methodNotFound("session/prompt")
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}
