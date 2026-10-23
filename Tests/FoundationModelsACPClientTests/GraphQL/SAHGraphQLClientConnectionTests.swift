import FoundationModelsACP
import Testing

import FoundationModelsACPClient

// The tests of `SAHGraphQLClient` over a real ACP connection. Each test
// connects a `ConnectionModel` to a `GraphQLTunnelStubAgent` in this process,
// over `InMemoryTransport.pair()`, and uses only the public API of the
// client. No wait reads a clock or polls.

/// The session of each request.
private let sessionId = SessionId(rawValue: "session-1")

/// The document of each query.
private let boardQuery = "query Board($id: ID!) { board(id: $id) { name } }"

/// The document of each subscription.
private let changesSubscription = "subscription Changes($after: String) { changes(after: $after) { cursor } }"

/// The variables of each subscription.
private let changesVariables: [String: JSONValue] = ["after": .string("cursor-7")]

/// The first result of a subscription.
private let firstEvent = SAH.GraphQL.ExecutionResult(data: .object(["changes": .object(["cursor": .string("c-1")])]))

/// The second result of a subscription.
private let secondEvent = SAH.GraphQL.ExecutionResult(data: .object(["changes": .object(["cursor": .string("c-2")])]))

/// The GraphQL errors of an `_sah/graphql/error`.
private let cursorExpiredErrors: [JSONValue] = [
    .object([
        "message": .string("The cursor expired."),
        "extensions": .object(["code": .string("CURSOR_EXPIRED")]),
    ])
]

/// A connection model to a stub agent, with the agent.
@MainActor
private struct TunnelConnection {
    /// The model of the client side.
    let model: ConnectionModel

    /// The agent of the other side.
    let agent: GraphQLTunnelStubAgent

    /// The agent side of the connection.
    let agentConnection: AgentSideConnection

    /// The client under test, over ``model``.
    var client: SAHGraphQLClient {
        SAHGraphQLClient(connection: model)
    }

    /// Connects a model to a new stub agent.
    ///
    /// - Parameter makeAgent: Makes the agent from the agent side of the
    ///   connection.
    /// - Returns: The connection. Disconnect its model in a `defer` right
    ///   after the call, so the close runs also when the test body throws.
    /// - Throws: An issue when the factory did not run. Before it throws, the
    ///   call disconnects the model.
    static func make(
        _ makeAgent: @escaping @Sendable (AgentSideConnection) -> GraphQLTunnelStubAgent
    ) async throws -> TunnelConnection {
        let made = ThreadSafeBuffer<GraphQLTunnelStubAgent>()
        let connections = ThreadSafeBuffer<AgentSideConnection>()
        let model = await InProcessAgent.makeConnection { connection in
            let agent = makeAgent(connection)
            made.append(agent)
            connections.append(connection)
            return agent
        }
        do {
            return TunnelConnection(
                model: model,
                agent: try #require(made.elements.last),
                agentConnection: try #require(connections.elements.last))
        } catch {
            await model.disconnect()
            throw error
        }
    }
}

/// Reads each element of a stream until it ends.
///
/// - Parameter stream: The stream.
/// - Returns: The elements, and the error that ended the stream, or `nil` for
///   a normal finish.
private func collect(
    _ stream: AsyncThrowingStream<JSONValue, any Error>
) async -> (elements: [JSONValue], error: (any Error)?) {
    var elements: [JSONValue] = []
    do {
        for try await element in stream {
            elements.append(element)
        }
        return (elements, nil)
    } catch {
        return (elements, error)
    }
}

/// Starts the board subscription of the tests on `client`.
///
/// - Parameter client: The client.
/// - Returns: The stream of the subscription.
private func subscribeToChanges(on client: SAHGraphQLClient) -> AsyncThrowingStream<JSONValue, any Error> {
    client.subscribe(
        endpoint: "kanban",
        sessionId: sessionId,
        document: changesSubscription,
        variables: changesVariables,
        operationName: "Changes"
    )
}

@MainActor
@Suite("SAHGraphQLClient over an ACP connection")
struct SAHGraphQLClientConnectionTests {
    @Test func executeSendsTheRequestOnTheWireAndGivesTheResult() async throws {
        let result = SAH.GraphQL.ExecutionResult(data: .object(["board": .object(["name": .string("Work")])]))
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, executeResult: result) }
        defer { await tunnel.model.disconnect() }

        let answer = try await tunnel.client.execute(
            endpoint: "kanban",
            sessionId: sessionId,
            document: boardQuery,
            variables: ["id": .string("board-1")],
            operationName: "Board"
        )

        #expect(answer == .object(["data": .object(["board": .object(["name": .string("Work")])])]))
        let expected = SAH.GraphQL.ExecuteRequest(
            endpoint: "kanban",
            sessionId: sessionId,
            query: boardQuery,
            variables: .object(["id": .string("board-1")]),
            operationName: "Board"
        )
        #expect(tunnel.agent.executeRequests.elements == [expected])
    }

    @Test func executeGivesTheGraphQLErrorsOfTheResultWithNoThrow() async throws {
        let result = SAH.GraphQL.ExecutionResult(errors: cursorExpiredErrors)
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, executeResult: result) }
        defer { await tunnel.model.disconnect() }

        let answer = try await tunnel.client.execute(endpoint: "kanban", sessionId: nil, document: boardQuery)

        #expect(answer == .object(["errors": .array(cursorExpiredErrors)]))
    }

    @Test func executeOnAClosedConnectionThrowsConnectionClosed() async throws {
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0) }
        await tunnel.model.disconnect()

        await #expect(throws: SAHGraphQLError.connectionClosed) {
            try await tunnel.client.execute(endpoint: "kanban", sessionId: sessionId, document: boardQuery)
        }
        #expect(tunnel.agent.executeRequests.elements.isEmpty)
    }

    @Test func endpointsGivesTheListOfTheAgent() async throws {
        let list = [
            SAH.GraphQL.Endpoint(name: "kanban", version: "1", scope: .sessionFolder, schema: "type Query { x: Int }"),
            SAH.GraphQL.Endpoint(name: "settings", version: "2", scope: .server, schema: "type Query { y: Int }"),
        ]
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, endpointList: list) }
        defer { await tunnel.model.disconnect() }

        let endpoints = try await tunnel.client.endpoints()

        #expect(
            endpoints == [
                SAHGraphQLClient.Endpoint(
                    name: "kanban", version: "1", scope: .sessionFolder, schema: "type Query { x: Int }"),
                SAHGraphQLClient.Endpoint(name: "settings", version: "2", scope: .server, schema: "type Query { y: Int }"),
            ])
    }

    @Test func endpointsLeavesOutAnEndpointWithAScopeThatTheClientDoesNotKnow() async throws {
        let list = [
            SAH.GraphQL.Endpoint(
                name: "future", version: "1", scope: SAH.GraphQL.Scope(rawValue: "galaxy"), schema: "type Query { z: Int }"),
            SAH.GraphQL.Endpoint(name: "settings", version: "2", scope: .server, schema: "type Query { y: Int }"),
        ]
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, endpointList: list) }
        defer { await tunnel.model.disconnect() }

        let endpoints = try await tunnel.client.endpoints()

        #expect(endpoints.map(\.name) == ["settings"])
    }

    @Test func endpointsOnAClosedConnectionThrowsConnectionClosed() async throws {
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0) }
        await tunnel.model.disconnect()

        await #expect(throws: SAHGraphQLError.connectionClosed) {
            try await tunnel.client.endpoints()
        }
    }

    @Test func subscribeSendsTheRequestWithANewSubscriptionId() async throws {
        let script = GraphQLSubscriptionScript(end: .complete)
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, subscription: script) }
        defer { await tunnel.model.disconnect() }

        let subscriptionCount = 2
        for _ in 0..<subscriptionCount {
            _ = await collect(subscribeToChanges(on: tunnel.client))
        }

        let requests = tunnel.agent.subscribeRequests.elements
        #expect(requests.count == subscriptionCount)
        let request = try #require(requests.first)
        #expect(request.endpoint == "kanban")
        #expect(request.sessionId == sessionId)
        #expect(request.query == changesSubscription)
        #expect(request.variables == .object(changesVariables))
        #expect(request.operationName == "Changes")
        #expect(Set(requests.map(\.subscriptionId)).count == requests.count)
    }

    @Test func subscribeGivesEachNextAndFinishesNormallyAtComplete() async throws {
        let script = GraphQLSubscriptionScript(events: [firstEvent, secondEvent], end: .complete)
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, subscription: script) }
        defer { await tunnel.model.disconnect() }

        let (elements, error) = await collect(subscribeToChanges(on: tunnel.client))

        #expect(
            elements == [
                .object(["data": .object(["changes": .object(["cursor": .string("c-1")])])]),
                .object(["data": .object(["changes": .object(["cursor": .string("c-2")])])]),
            ])
        #expect(error == nil)
        #expect(tunnel.agent.unsubscribes.elements.isEmpty)
    }

    @Test func aNextOfAnotherSubscriptionIdDoesNotReachTheStream() async throws {
        let script = GraphQLSubscriptionScript(events: [secondEvent], foreignEvents: [firstEvent], end: .complete)
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, subscription: script) }
        defer { await tunnel.model.disconnect() }

        let (elements, error) = await collect(subscribeToChanges(on: tunnel.client))

        #expect(elements == [.object(["data": .object(["changes": .object(["cursor": .string("c-2")])])])])
        #expect(error == nil)
    }

    @Test func subscribeThrowsTheGraphQLErrorsOfAnErrorNotification() async throws {
        let script = GraphQLSubscriptionScript(events: [firstEvent], end: .error(cursorExpiredErrors))
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, subscription: script) }
        defer { await tunnel.model.disconnect() }

        let (elements, error) = await collect(subscribeToChanges(on: tunnel.client))

        #expect(elements.count == 1)
        #expect(error as? SAHGraphQLError == .graphQL(.array(cursorExpiredErrors)))
        #expect(tunnel.agent.unsubscribes.elements.isEmpty)
    }

    @Test func subscribeThrowsTheRefusalOfTheSubscribeRequest() async throws {
        let refusal = RequestError(code: .invalidParams, message: "the subscription id is in use")
        let script = GraphQLSubscriptionScript(refusal: refusal)
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, subscription: script) }
        defer { await tunnel.model.disconnect() }

        let (elements, error) = await collect(subscribeToChanges(on: tunnel.client))

        #expect(elements.isEmpty)
        #expect((error as? RequestError)?.code == .invalidParams)
    }

    @Test func subscribeThrowsConnectionClosedWhenTheConnectionCloses() async throws {
        let script = GraphQLSubscriptionScript(events: [firstEvent], end: .hold)
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, subscription: script) }
        defer { await tunnel.model.disconnect() }
        var iterator = subscribeToChanges(on: tunnel.client).makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first != nil)

        await tunnel.agentConnection.close()

        var ending: (any Error)?
        do {
            _ = try await iterator.next()
        } catch {
            ending = error
        }
        #expect(ending as? SAHGraphQLError == .connectionClosed)
    }

    @Test func subscribeOnAClosedConnectionThrowsConnectionClosed() async throws {
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0) }
        await tunnel.model.disconnect()

        let (elements, error) = await collect(subscribeToChanges(on: tunnel.client))

        #expect(elements.isEmpty)
        #expect(error as? SAHGraphQLError == .connectionClosed)
        #expect(tunnel.agent.subscribeRequests.elements.isEmpty)
    }

    @Test func aStoppedIterationSendsUnsubscribeWithTheSubscriptionId() async throws {
        let script = GraphQLSubscriptionScript(events: [firstEvent], end: .hold)
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, subscription: script) }
        defer { await tunnel.model.disconnect() }
        let stream = subscribeToChanges(on: tunnel.client)

        // The caller reads one element, and then its task stops the
        // iteration.
        let (firstElements, firstContinuation) = AsyncStream<JSONValue>.makeStream()
        let reading = Task {
            for try await element in stream {
                firstContinuation.yield(element)
            }
        }
        var firstIterator = firstElements.makeAsyncIterator()
        #expect(await firstIterator.next() != nil)
        reading.cancel()
        firstContinuation.finish()

        let model = tunnel.model
        try await waitUntil { !tunnel.agent.unsubscribes.elements.isEmpty } orFailWhen: {
            model.state != .connected
        }
        let subscribed = try #require(tunnel.agent.subscribeRequests.elements.first)
        #expect(tunnel.agent.unsubscribes.elements == [subscribed.subscriptionId])
    }
}
