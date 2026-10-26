import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import GraphQL
import Synchronization

/// An agent that serves the `_sah/graphql/*` methods of the GraphQL tunnel
/// over one real `GraphQLEndpoint`, for example `KanbanGraph`.
///
/// The agent does what the tunnel of FoundationModelsACPAgent does, in a
/// small form: it gives the variables of a call to the endpoint as `Map`
/// values, gives the viewer of the connection with each call, and sends each
/// JSON text of the endpoint back as a GraphQL result. The package must not
/// link FoundationModelsACPAgent, so the tests use this agent in its place.
///
/// The session methods of `Agent` answer method-not-found: the tests send no
/// session request.
final class EndpointTunnelAgent: Agent {
    /// The connection back to the client.
    private let connection: AgentSideConnection

    /// The endpoint that answers each call.
    private let endpoint: any GraphQLEndpoint

    /// The viewer that the agent gives with each call: the client of the
    /// connection, as the agent knows it.
    private let viewer: GraphQLViewer?

    /// The task that forwards the events of each open subscription, by
    /// subscription id.
    private let forwards = Mutex<[SAH.GraphQL.SubscriptionId: Task<Void, Never>]>([:])

    /// The session id of each `_sah/graphql/execute` and
    /// `_sah/graphql/subscribe`, in arrival order.
    let sessionIds = ThreadSafeBuffer<SessionId?>()

    /// One element for each subscription that the endpoint started, before
    /// the agent answers its `_sah/graphql/subscribe`.
    let startedSubscriptions: AsyncStream<SAH.GraphQL.SubscriptionId>

    /// The continuation of ``startedSubscriptions``.
    private let started: AsyncStream<SAH.GraphQL.SubscriptionId>.Continuation

    /// Makes the agent.
    ///
    /// - Parameters:
    ///   - connection: The connection back to the client.
    ///   - endpoint: The endpoint that answers each call.
    ///   - viewer: The viewer that the agent gives with each call.
    init(connection: AgentSideConnection, endpoint: any GraphQLEndpoint, viewer: GraphQLViewer?) {
        self.connection = connection
        self.endpoint = endpoint
        self.viewer = viewer
        (startedSubscriptions, started) = AsyncStream<SAH.GraphQL.SubscriptionId>.makeStream()
    }

    var extensionHandlers: ExtensionHandlers {
        var handlers = ExtensionHandlers()
        handlers.registerMethod(SAH.GraphQL.Method.execute, params: SAH.GraphQL.ExecuteRequest.self) { request in
            self.sessionIds.append(request.sessionId)
            let text = try await self.endpoint.execute(
                query: request.query, variables: try Self.variables(request.variables),
                operationName: request.operationName, viewer: self.viewer)
            return try Self.result(of: text)
        }
        handlers.registerMethod(SAH.GraphQL.Method.endpoints, params: SAH.GraphQL.EndpointsRequest.self) { _ in
            SAH.GraphQL.EndpointsResponse(endpoints: [
                SAH.GraphQL.Endpoint(
                    name: self.endpoint.name, version: self.endpoint.version,
                    scope: SAH.GraphQL.Scope(rawValue: self.endpoint.scope.rawValue), schema: self.endpoint.schema)
            ])
        }
        handlers.registerMethod(SAH.GraphQL.Method.subscribe, params: SAH.GraphQL.SubscribeRequest.self) { request in
            try await self.subscribe(request)
        }
        handlers.registerNotification(
            SAH.GraphQL.Method.unsubscribe, params: SAH.GraphQL.UnsubscribeNotification.self
        ) { notification in
            self.forwards.withLock { $0.removeValue(forKey: notification.subscriptionId) }?.cancel()
        }
        return handlers
    }

    /// Serves one `_sah/graphql/subscribe`: starts the subscription of the
    /// endpoint, and forwards each event in a task until the stream ends.
    ///
    /// - Parameter request: The params of the call.
    /// - Returns: The answer that tells that the subscription started.
    /// - Throws: The error of the start of the subscription.
    private func subscribe(_ request: SAH.GraphQL.SubscribeRequest) async throws -> SAH.GraphQL.SubscribeResponse {
        sessionIds.append(request.sessionId)
        let events = try await endpoint.subscribe(
            query: request.query, variables: try Self.variables(request.variables),
            operationName: request.operationName, viewer: viewer)
        let id = request.subscriptionId
        let forward = Task {
            do {
                for try await text in events {
                    try await self.connection.sendExtensionNotification(
                        SAH.GraphQL.Method.next,
                        SAH.GraphQL.NextNotification(subscriptionId: id, payload: try Self.result(of: text)))
                }
                try await self.connection.sendExtensionNotification(
                    SAH.GraphQL.Method.complete, SAH.GraphQL.CompleteNotification(subscriptionId: id))
            } catch {
                // A cancelled forward is an unsubscribe, or the close of the
                // connection: the client waits for no message.
            }
        }
        forwards.withLock { $0[id] = forward }
        started.yield(id)
        return SAH.GraphQL.SubscribeResponse()
    }

    /// Gives the variables of a call as the `Map` values of the endpoint.
    ///
    /// - Parameter variables: The variables of the call, or `nil`.
    /// - Returns: The values; no variables give none.
    /// - Throws: An error of the JSON coders.
    private static func variables(_ variables: JSONValue?) throws -> [String: Map] {
        guard let variables, variables != .null else {
            return [:]
        }
        return try JSONDecoder().decode([String: Map].self, from: JSONEncoder().encode(variables))
    }

    /// Reads the JSON text of a response of the endpoint as a result of the
    /// tunnel.
    ///
    /// - Parameter text: The `{data, errors}` JSON text.
    /// - Returns: The result.
    /// - Throws: A `DecodingError` when the text is not a GraphQL response.
    private static func result(of text: String) throws -> SAH.GraphQL.ExecutionResult {
        try JSONDecoder().decode(SAH.GraphQL.ExecutionResult.self, from: Data(text.utf8))
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
