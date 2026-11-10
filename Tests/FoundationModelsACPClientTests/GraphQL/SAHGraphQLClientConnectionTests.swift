import Foundation
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

/// The `method` member of one JSON-RPC frame.
private struct FrameMethod: Decodable {
    /// The method of a request or a notification, or `nil` for a response.
    let method: String?
}

/// A connection model to a stub agent that records each frame that the
/// client writes, in wire order.
///
/// The frames prove which `_sah/graphql/endpoints` requests went out, in the
/// order of the wire.
@MainActor
private struct RecordedTunnelConnection {
    /// The model of the client side.
    let model: ConnectionModel

    /// The agent side of the connection. The test holds it so the agent end
    /// of the pair outlives the test body.
    let agentConnection: AgentSideConnection

    /// Each line that the client wrote to the agent end.
    private let lines: ThreadSafeBuffer<String>

    /// The client under test, over ``model``.
    var client: SAHGraphQLClient {
        SAHGraphQLClient(connection: model)
    }

    /// The method of each request and notification that the client wrote, in
    /// wire order.
    var sentMethods: [String] {
        lines.elements.compactMap { try? JSONDecoder().decode(FrameMethod.self, from: Data($0.utf8)).method }
    }

    /// Makes a connection from its parts. The initializer only assigns the
    /// stored properties; ``make(initializeMeta:)`` connects and sends
    /// `initialize`.
    ///
    /// - Parameters:
    ///   - model: The model of the client side.
    ///   - agentConnection: The agent side of the connection.
    ///   - lines: Gets each line that the client writes to the agent end.
    private init(model: ConnectionModel, agentConnection: AgentSideConnection, lines: ThreadSafeBuffer<String>) {
        self.model = model
        self.agentConnection = agentConnection
        self.lines = lines
    }

    /// Connects a new model to a new stub agent, and sends `initialize`.
    ///
    /// - Parameter initializeMeta: The SAH object of the `initialize` answer
    ///   of the agent, or `nil` for an answer with no `_meta`.
    /// - Returns: The connection. Disconnect its model in a `defer` right
    ///   after the call, so the close runs also when the test body throws.
    /// - Throws: The error of the `initialize`. Before it throws, the call
    ///   disconnects the model.
    static func make(initializeMeta: SAH.InitializeMeta?) async throws -> RecordedTunnelConnection {
        let lines = ThreadSafeBuffer<String>()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let recordedAgentEnd = FrameRecordingTransport(wrapping: agentEnd) { lines.append($0) }
        let agentConnection = await AgentSideConnection(stream: recordedAgentEnd) { connection in
            GraphQLTunnelStubAgent(
                connection: connection, endpointList: [requestEndpoint], initializeMeta: initializeMeta)
        }
        let model = ConnectionModel()
        _ = await model.connect(over: clientEnd)
        do {
            _ = try await model.initialize(makeInitializeRequest())
        } catch {
            await model.disconnect()
            throw error
        }
        return RecordedTunnelConnection(model: model, agentConnection: agentConnection, lines: lines)
    }
}

/// The endpoint of the `initialize` answer in the tests of the SAH object. It
/// is not in the `_sah/graphql/endpoints` answer, so a test can tell the two
/// lists apart.
private let initializeEndpoint = SAH.GraphQL.Endpoint(
    name: "kanban", version: "1", scope: .sessionFolder, schema: "type Query { x: Int }")

/// The only endpoint of the `_sah/graphql/endpoints` answer in the tests of
/// the SAH object: the live list of the agent.
private let requestEndpoint = SAH.GraphQL.Endpoint(
    name: "settings", version: "2", scope: .server, schema: "type Query { y: Int }")

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

    @Test func endpointsWithASAHObjectSendsTheRequestAndGivesTheLiveList() async throws {
        let tunnel = try await RecordedTunnelConnection.make(
            initializeMeta: SAH.InitializeMeta(graphql: [initializeEndpoint]))
        defer { await tunnel.model.disconnect() }

        let endpoints = try await tunnel.client.endpoints()

        #expect(
            endpoints == [
                SAHGraphQLClient.Endpoint(
                    name: "settings", version: "2", scope: .server, schema: "type Query { y: Int }")
            ])
        #expect(tunnel.sentMethods.contains(SAH.GraphQL.Method.endpoints))
    }

    @Test func endpointsWithNoSAHObjectSendsTheRequest() async throws {
        let tunnel = try await RecordedTunnelConnection.make(initializeMeta: nil)
        defer { await tunnel.model.disconnect() }

        let endpoints = try await tunnel.client.endpoints()

        #expect(
            endpoints == [
                SAHGraphQLClient.Endpoint(
                    name: "settings", version: "2", scope: .server, schema: "type Query { y: Int }")
            ])
        #expect(tunnel.sentMethods.contains(SAH.GraphQL.Method.endpoints))
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
            _ = await subscribeToChanges(on: tunnel.client).collect()
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

        let (elements, error) = await subscribeToChanges(on: tunnel.client).collect()

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

        let (elements, error) = await subscribeToChanges(on: tunnel.client).collect()

        #expect(elements == [.object(["data": .object(["changes": .object(["cursor": .string("c-2")])])])])
        #expect(error == nil)
    }

    @Test func subscribeThrowsTheGraphQLErrorsOfAnErrorNotification() async throws {
        let script = GraphQLSubscriptionScript(events: [firstEvent], end: .error(cursorExpiredErrors))
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, subscription: script) }
        defer { await tunnel.model.disconnect() }

        let (elements, error) = await subscribeToChanges(on: tunnel.client).collect()

        #expect(elements.count == 1)
        #expect(error as? SAHGraphQLError == .graphQL(.array(cursorExpiredErrors)))
        #expect(tunnel.agent.unsubscribes.elements.isEmpty)
    }

    @Test func subscribeThrowsTheRefusalOfTheSubscribeRequest() async throws {
        let refusal = RequestError(code: .invalidParams, message: "the subscription id is in use")
        let script = GraphQLSubscriptionScript(refusal: refusal)
        let tunnel = try await TunnelConnection.make { GraphQLTunnelStubAgent(connection: $0, subscription: script) }
        defer { await tunnel.model.disconnect() }

        let (elements, error) = await subscribeToChanges(on: tunnel.client).collect()

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

        let (elements, error) = await subscribeToChanges(on: tunnel.client).collect()

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
