import Foundation
import FoundationModelsACP

/// The calls that a ``SAHGraphQLClient`` gives to the place that answers
/// them: a stub handler, or an ACP connection.
protocol SAHGraphQLBackend: Sendable {
    /// Runs a query or a mutation.
    ///
    /// - Parameter request: The operation.
    /// - Returns: The GraphQL result, with its `data` and `errors` members.
    /// - Throws: ``SAHGraphQLError/connectionClosed`` for a lost connection,
    ///   or another error of the backend.
    func execute(_ request: SAHGraphQLClient.Request) async throws -> JSONValue

    /// Starts a subscription.
    ///
    /// - Parameter request: The subscription operation.
    /// - Returns: The stream of the GraphQL results.
    func subscribe(_ request: SAHGraphQLClient.Request) -> AsyncThrowingStream<JSONValue, any Error>

    /// Lists the endpoints.
    ///
    /// - Returns: The endpoints.
    /// - Throws: ``SAHGraphQLError/connectionClosed`` for a lost connection,
    ///   or another error of the backend.
    func endpoints() async throws -> [SAHGraphQLClient.Endpoint]
}

/// The backend of a ``SAHGraphQLClient`` over a stub handler.
struct StubGraphQLBackend: SAHGraphQLBackend {
    /// The handler that answers each call.
    let stub: any SAHGraphQLStubHandler

    func execute(_ request: SAHGraphQLClient.Request) async throws -> JSONValue {
        try await stub.execute(request)
    }

    func subscribe(_ request: SAHGraphQLClient.Request) -> AsyncThrowingStream<JSONValue, any Error> {
        stub.subscribe(request)
    }

    func endpoints() async throws -> [SAHGraphQLClient.Endpoint] {
        try await stub.endpoints()
    }
}

/// The open connection of a ``ConnectionModel``, with the GraphQL
/// subscriptions and the diagnostic sink of that connection.
struct SAHGraphQLRoute: Sendable {
    /// The open connection.
    let connection: ClientSideConnection

    /// The GraphQL subscriptions of ``connection``.
    let subscriptions: SAHGraphQLSubscriptions

    /// The diagnostic sink of ``connection``; never stdout.
    let logger: ACPLogger
}

extension ConnectionModel {
    /// The open connection and its GraphQL subscriptions.
    ///
    /// - Returns: The route of the open connection.
    /// - Throws: ``SAHGraphQLError/connectionClosed`` when no connection is
    ///   open.
    func graphQLRoute() throws -> SAHGraphQLRoute {
        guard let connection, let graphQLSubscriptions else {
            throw SAHGraphQLError.connectionClosed
        }
        return SAHGraphQLRoute(connection: connection, subscriptions: graphQLSubscriptions, logger: connectionLogger)
    }
}

/// The backend of a ``SAHGraphQLClient`` over the ACP connection of a
/// ``ConnectionModel``: it sends the `_sah/graphql/*` messages.
///
/// Each call uses the connection that is open when the call starts. A
/// connection that closes during a call gives
/// ``SAHGraphQLError/connectionClosed``.
struct ConnectionGraphQLBackend: SAHGraphQLBackend {
    /// The text that starts each diagnostic of the backend.
    private static let logPrefix = "SAHGraphQLClient: "

    /// The client scope of each wire scope that the client knows.
    private static let clientScopes: [SAH.GraphQL.Scope: SAHGraphQLClient.Endpoint.Scope] = [
        .sessionFolder: .sessionFolder,
        .server: .server,
    ]

    /// The model whose open connection carries each call.
    let model: ConnectionModel

    func execute(_ request: SAHGraphQLClient.Request) async throws -> JSONValue {
        let route = try await model.graphQLRoute()
        let result = try await Self.mappingClose {
            try await route.connection.callExtensionMethod(
                SAH.GraphQL.Method.execute, request.executeParams, returning: SAH.GraphQL.ExecutionResult.self)
        }
        return result.jsonValue
    }

    /// Starts the subscription in a task, and gives its stream at once.
    ///
    /// The task routes the new subscription id before it sends
    /// `_sah/graphql/subscribe`, because the agent can send
    /// `_sah/graphql/next` before its answer. The task ends when the
    /// subscribe request has its answer. When the caller stops the iteration,
    /// a second task waits for that answer, and then sends
    /// `_sah/graphql/unsubscribe`. Thus the agent gets the unsubscribe after
    /// it started the subscription.
    func subscribe(_ request: SAHGraphQLClient.Request) -> AsyncThrowingStream<JSONValue, any Error> {
        let id = SAH.GraphQL.SubscriptionId(rawValue: UUID().uuidString)
        let (stream, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        let model = model
        let start = Task {
            await Self.start(request, id: id, continuation: continuation, on: model)
        }
        continuation.onTermination = { termination in
            guard case .cancelled = termination else {
                return
            }
            Task {
                await Self.stop(id, startedBy: start)
            }
        }
        return stream
    }

    func endpoints() async throws -> [SAHGraphQLClient.Endpoint] {
        let route = try await model.graphQLRoute()
        let response = try await Self.mappingClose {
            try await route.connection.callExtensionMethod(
                SAH.GraphQL.Method.endpoints, SAH.GraphQL.EndpointsRequest(),
                returning: SAH.GraphQL.EndpointsResponse.self)
        }
        return response.endpoints.compactMap { Self.clientEndpoint(of: $0, logger: route.logger) }
    }

    /// Routes one subscription and sends `_sah/graphql/subscribe`.
    ///
    /// - Parameters:
    ///   - request: The subscription operation.
    ///   - id: The new subscription id.
    ///   - continuation: The continuation of the stream of the subscription.
    ///   - model: The model whose open connection carries the subscription.
    /// - Returns: The route that carries the subscription, or `nil` when the
    ///   subscription did not start. Then the stream is finished with the
    ///   error.
    private static func start(
        _ request: SAHGraphQLClient.Request,
        id: SAH.GraphQL.SubscriptionId,
        continuation: SAHGraphQLSubscriptions.Continuation,
        on model: ConnectionModel
    ) async -> SAHGraphQLRoute? {
        do {
            let route = try await model.graphQLRoute()
            guard route.subscriptions.open(id, continuation) else {
                throw SAHGraphQLError.connectionClosed
            }
            do {
                _ = try await mappingClose {
                    try await route.connection.callExtensionMethod(
                        SAH.GraphQL.Method.subscribe, request.subscribeParams(id: id),
                        returning: SAH.GraphQL.SubscribeResponse.self)
                }
            } catch {
                route.subscriptions.remove(id)
                throw error
            }
            return route
        } catch {
            continuation.finish(throwing: error)
            return nil
        }
    }

    /// Stops one subscription whose caller stopped the iteration.
    ///
    /// The call waits until the subscribe request has its answer. It sends
    /// `_sah/graphql/unsubscribe` only when the subscription started and is
    /// still open: a subscription that `complete`, `error` or the close of
    /// the connection ended needs no unsubscribe.
    ///
    /// - Parameters:
    ///   - id: The subscription id.
    ///   - start: The task that started the subscription.
    private static func stop(_ id: SAH.GraphQL.SubscriptionId, startedBy start: Task<SAHGraphQLRoute?, Never>) async {
        guard let route = await start.value, route.subscriptions.remove(id) != nil else {
            return
        }
        do {
            try await route.connection.sendExtensionNotification(
                SAH.GraphQL.Method.unsubscribe, SAH.GraphQL.UnsubscribeNotification(subscriptionId: id))
        } catch {
            // The connection closed after the answer, so the agent stopped
            // the subscription itself. The log records the lost message.
            route.logger.log(logPrefix + "the unsubscribe of a subscription did not reach the agent: \(type(of: error))")
        }
    }

    /// Gives the endpoint of the client for one endpoint of the wire.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint of the wire.
    ///   - logger: The diagnostic sink of the connection.
    /// - Returns: The endpoint, or `nil` when the client does not know its
    ///   scope. Then the call logs one diagnostic.
    private static func clientEndpoint(
        of endpoint: SAH.GraphQL.Endpoint, logger: ACPLogger
    ) -> SAHGraphQLClient.Endpoint? {
        guard let scope = clientScopes[endpoint.scope] else {
            logger.log(
                logPrefix + "left out the endpoint \"\(endpoint.name)\", because the client does not know its scope "
                    + "\"\(endpoint.scope.rawValue)\"")
            return nil
        }
        return SAHGraphQLClient.Endpoint(
            name: endpoint.name, version: endpoint.version, scope: scope, schema: endpoint.schema)
    }

    /// Runs one call on the connection, and gives
    /// ``SAHGraphQLError/connectionClosed`` for a closed connection.
    ///
    /// - Parameter call: The call.
    /// - Returns: The result of the call.
    /// - Throws: ``SAHGraphQLError/connectionClosed`` when the connection
    ///   closed, or each other error of the call.
    private static func mappingClose<Result>(_ call: () async throws -> Result) async throws -> Result {
        do {
            return try await call()
        } catch ConnectionError.closed {
            throw SAHGraphQLError.connectionClosed
        }
    }
}

extension SAHGraphQLClient.Request {
    /// The params of `_sah/graphql/execute` for this request.
    var executeParams: SAH.GraphQL.ExecuteRequest {
        SAH.GraphQL.ExecuteRequest(
            endpoint: endpoint, sessionId: sessionId, query: document, variables: .object(variables),
            operationName: operationName)
    }

    /// The params of `_sah/graphql/subscribe` for this request.
    ///
    /// - Parameter id: The new subscription id.
    /// - Returns: The params.
    func subscribeParams(id: SAH.GraphQL.SubscriptionId) -> SAH.GraphQL.SubscribeRequest {
        SAH.GraphQL.SubscribeRequest(
            subscriptionId: id, endpoint: endpoint, sessionId: sessionId, query: document,
            variables: .object(variables), operationName: operationName)
    }
}
