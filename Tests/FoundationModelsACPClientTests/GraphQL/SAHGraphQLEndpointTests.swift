import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsKanban
import GraphQL
import Testing

import FoundationModelsACPClient

// The tests of `SAHGraphQLEndpoint`: one endpoint of the server as a
// `GraphQLEndpoint`, over the `_sah/graphql/*` tunnel of a connection.
//
// The kanban tests connect a `ConnectionModel` to an `EndpointTunnelAgent` in
// this process, over `InMemoryTransport.pair()`. The agent serves a real
// `KanbanGraph` over a new board in a temporary folder. Each test sends one
// document through the tunnel endpoint and the same document to the
// `KanbanGraph` directly, and compares the two JSON texts. The other tests
// use the `GraphQLTunnelStubAgent`. No wait reads a clock or polls.

/// The session of each request.
private let sessionId = SessionId(rawValue: "session-1")

/// The name of the kanban endpoint.
private let kanbanEndpoint = "kanban"

/// The mutation that makes the board.
private let initBoardMutation = "mutation InitBoard($input: InitBoardInput!) { initBoard(input: $input) { id } }"

/// The mutation that adds a task.
private let addTaskMutation = "mutation AddTask($input: AddTaskInput!) { addTask(input: $input) { id } }"

/// The query of the board of the session.
private let boardQuery = "query Board { board { id name } }"

/// The subscription to the changes of the board.
private let changesSubscription = "subscription Changes($after: String) { changes(after: $after) { cursor updates { id } } }"

/// The GraphQL errors of an `_sah/graphql/error`.
private let cursorExpiredErrors: [JSONValue] = [
    .object([
        "message": .string("The cursor expired."),
        "extensions": .object(["code": .string("CURSOR_EXPIRED")]),
    ])
]

/// A `KanbanGraph` over a new board, served by an in-process agent, and a
/// connection model to that agent.
@MainActor
private struct KanbanTunnel {
    /// The temporary folder of the board.
    let folder: URL

    /// The endpoint that the agent serves.
    let graph: KanbanGraph

    /// The model of the client side.
    let model: ConnectionModel

    /// The agent of the other side.
    let agent: EndpointTunnelAgent

    /// The client over ``model``.
    var client: SAHGraphQLClient {
        SAHGraphQLClient(connection: model)
    }

    /// Makes a board in a new temporary folder, and connects a model to an
    /// agent that serves its `KanbanGraph`.
    ///
    /// - Parameter viewer: The viewer that the agent gives with each call.
    /// - Returns: The tunnel. Call ``close()`` in a `defer` right after the
    ///   call, so the close runs also when the test body throws.
    /// - Throws: The error of the folder, of the endpoint or of `initBoard`.
    ///   Before it throws, the call closes what it made.
    static func make(viewer: GraphQLViewer? = nil) async throws -> KanbanTunnel {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "acp-client-endpoint-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let graph: KanbanGraph
        do {
            graph = try await KanbanHost.shared.session(workingDirectory: folder, actor: "tester")
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let made = ThreadSafeBuffer<EndpointTunnelAgent>()
        let model = await InProcessAgent.makeConnection { connection in
            let agent = EndpointTunnelAgent(connection: connection, endpoint: graph, viewer: viewer)
            made.append(agent)
            return agent
        }
        do {
            let tunnel = KanbanTunnel(folder: folder, graph: graph, model: model, agent: try #require(made.elements.last))
            let response = try await graph.execute(
                query: initBoardMutation, variables: ["input": ["name": "Work"]], operationName: nil, viewer: nil)
            #expect(errorCodes(in: response) == [], "\(response)")
            return tunnel
        } catch {
            await model.disconnect()
            await graph.close()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The kanban endpoint of the session, through the tunnel.
    ///
    /// - Returns: The endpoint.
    /// - Throws: The error of ``SAHGraphQLClient/endpoint(named:sessionId:)``.
    func tunnelEndpoint() async throws -> SAHGraphQLEndpoint {
        try await client.endpoint(named: kanbanEndpoint, sessionId: sessionId)
    }

    /// Closes the connection and the endpoint, and removes the folder.
    func close() async {
        await model.disconnect()
        await graph.close()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Connects a model to a new stub agent.
///
/// - Parameter makeAgent: Makes the agent from the agent side of the
///   connection.
/// - Returns: The model and the agent. Disconnect the model in a `defer`
///   right after the call.
/// - Throws: An issue when the factory did not run. Before it throws, the
///   call disconnects the model.
@MainActor
private func connectStub(
    _ makeAgent: @escaping @Sendable (AgentSideConnection) -> GraphQLTunnelStubAgent
) async throws -> (model: ConnectionModel, agent: GraphQLTunnelStubAgent) {
    let made = ThreadSafeBuffer<GraphQLTunnelStubAgent>()
    let model = await InProcessAgent.makeConnection { connection in
        let agent = makeAgent(connection)
        made.append(agent)
        return agent
    }
    do {
        return (model, try #require(made.elements.last))
    } catch {
        await model.disconnect()
        throw error
    }
}

/// The `extensions.code` of each GraphQL error of a JSON response.
///
/// - Parameter text: The JSON text of the response.
/// - Returns: The codes, in order; an error with no code gives no entry.
private func errorCodes(in text: String) -> [String] {
    guard case .object(let response)? = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
        case .array(let errors)? = response["errors"]
    else {
        return []
    }
    return errors.compactMap { error in
        guard case .object(let error) = error,
            case .object(let extensions)? = error["extensions"],
            case .string(let code)? = extensions["code"]
        else {
            return nil
        }
        return code
    }
}

@MainActor
@Suite("SAHGraphQLEndpoint over an ACP connection")
struct SAHGraphQLEndpointTests {
    @Test func theEndpointHasTheNameVersionScopeAndSchemaOfTheServer() async throws {
        let tunnel = try await KanbanTunnel.make()
        defer { await tunnel.close() }

        let endpoint = try await tunnel.tunnelEndpoint()

        #expect(endpoint.name == tunnel.graph.name)
        #expect(endpoint.version == tunnel.graph.version)
        #expect(endpoint.scope == .sessionFolder)
        #expect(endpoint.schema == tunnel.graph.schema)
        #expect(endpoint.sessionId == sessionId)
    }

    @Test func aQueryGivesTheSameTextThroughTheTunnelAsKanbanGraphGives() async throws {
        let tunnel = try await KanbanTunnel.make()
        defer { await tunnel.close() }
        let endpoint = try await tunnel.tunnelEndpoint()

        let direct = try await tunnel.graph.execute(
            query: boardQuery, variables: [:], operationName: "Board", viewer: nil)
        let throughTunnel = try await endpoint.execute(
            query: boardQuery, variables: [:], operationName: "Board", viewer: nil)

        #expect(errorCodes(in: direct) == [], "\(direct)")
        // The board id is a `kanban://` URI, so the texts are equal only
        // when the tunnel endpoint does not escape the slashes.
        #expect(direct.contains("kanban://"))
        #expect(throughTunnel == direct)
        #expect(tunnel.agent.sessionIds.elements == [sessionId])
    }

    @Test func aMutationThroughTheTunnelGivesOneSubscriptionEvent() async throws {
        let tunnel = try await KanbanTunnel.make()
        defer { await tunnel.close() }
        let endpoint = try await tunnel.tunnelEndpoint()
        var direct = try await tunnel.graph.subscribe(
            query: changesSubscription, variables: [:], operationName: nil, viewer: nil
        ).makeAsyncIterator()
        var started = tunnel.agent.startedSubscriptions.makeAsyncIterator()
        var throughTunnel = try await endpoint.subscribe(
            query: changesSubscription, variables: [:], operationName: nil, viewer: nil
        ).makeAsyncIterator()
        // The mutation goes after the start of the subscription on the agent,
        // so the subscription gets its change.
        #expect(await started.next() != nil)

        let added = try await endpoint.execute(
            query: addTaskMutation, variables: ["input": ["title": "Write the tests"]], operationName: nil,
            viewer: nil)

        #expect(errorCodes(in: added) == [], "\(added)")
        let tunnelEvent = try await throughTunnel.next()
        let directEvent = try await direct.next()
        #expect(tunnelEvent != nil)
        #expect(tunnelEvent == directEvent)
    }

    @Test func anUnknownNameThrowsUnknownEndpoint() async throws {
        let tunnel = try await KanbanTunnel.make()
        defer { await tunnel.close() }

        await #expect(throws: SAHGraphQLEndpointError.unknownEndpoint(name: "noSuchEndpoint")) {
            try await tunnel.client.endpoint(named: "noSuchEndpoint", sessionId: sessionId)
        }
    }

    @Test func anExternalConnectionGetsUnreachableBoardForADifferentBoard() async throws {
        let external = GraphQLViewer(clientId: "client-1", trust: .external)
        let tunnel = try await KanbanTunnel.make(viewer: external)
        defer { await tunnel.close() }
        let endpoint = try await tunnel.tunnelEndpoint()
        let otherBoard = FileManager.default.temporaryDirectory.appending(path: "acp-client-other-board").path
        let otherBoardQuery = #"{ board(id: "\#(otherBoard)") { name } }"#

        // The client gives no viewer: the agent fills it from the connection.
        let throughTunnel = try await endpoint.execute(
            query: otherBoardQuery, variables: [:], operationName: nil, viewer: nil)
        let direct = try await tunnel.graph.execute(
            query: otherBoardQuery, variables: [:], operationName: nil, viewer: external)

        #expect(errorCodes(in: throughTunnel) == ["UNREACHABLE_BOARD"], "\(throughTunnel)")
        #expect(throughTunnel == direct)
        let ownBoard = try await endpoint.execute(query: boardQuery, variables: [:], operationName: nil, viewer: nil)
        #expect(errorCodes(in: ownBoard) == [], "\(ownBoard)")
    }

    @Test func anEndpointWithTheServerScopeSendsNoSession() async throws {
        let list = [SAH.GraphQL.Endpoint(name: "settings", version: "2", scope: .server, schema: "type Query { y: Int }")]
        let result = SAH.GraphQL.ExecutionResult(data: .object(["y": .number(1)]))
        let (model, agent) = try await connectStub {
            GraphQLTunnelStubAgent(connection: $0, executeResult: result, endpointList: list)
        }
        defer { await model.disconnect() }

        let endpoint = try await SAHGraphQLClient(connection: model).endpoint(named: "settings", sessionId: sessionId)
        let answer = try await endpoint.execute(query: "{ y }", variables: [:], operationName: nil, viewer: nil)

        #expect(endpoint.scope == .server)
        #expect(endpoint.sessionId == nil)
        #expect(answer == #"{"data":{"y":1}}"#)
        #expect(agent.executeRequests.elements.map(\.sessionId) == [nil])
    }

    @Test func anEndpointWithTheSessionFolderScopeAndNoSessionThrowsMissingSession() async throws {
        let list = [SAH.GraphQL.Endpoint(name: "kanban", version: "2", scope: .sessionFolder, schema: "type Query { x: Int }")]
        let (model, _) = try await connectStub { GraphQLTunnelStubAgent(connection: $0, endpointList: list) }
        defer { await model.disconnect() }

        await #expect(throws: SAHGraphQLEndpointError.missingSession(endpoint: "kanban")) {
            try await SAHGraphQLClient(connection: model).endpoint(named: "kanban")
        }
    }

    @Test func anErrorNotificationGivesOneLastResponseWithTheErrors() async throws {
        let list = [SAH.GraphQL.Endpoint(name: "kanban", version: "2", scope: .sessionFolder, schema: "type Query { x: Int }")]
        let event = SAH.GraphQL.ExecutionResult(data: .object(["changes": .object(["cursor": .string("c/1")])]))
        let script = GraphQLSubscriptionScript(events: [event], end: .error(cursorExpiredErrors))
        let (model, _) = try await connectStub {
            GraphQLTunnelStubAgent(connection: $0, endpointList: list, subscription: script)
        }
        defer { await model.disconnect() }
        let endpoint = try await SAHGraphQLClient(connection: model).endpoint(named: "kanban", sessionId: sessionId)

        let (elements, error) = try await endpoint.subscribe(
            query: changesSubscription, variables: ["after": "c/0"], operationName: nil, viewer: nil
        ).collect()

        #expect(
            elements == [
                #"{"data":{"changes":{"cursor":"c/1"}}}"#,
                #"{"errors":[{"extensions":{"code":"CURSOR_EXPIRED"},"message":"The cursor expired."}]}"#,
            ])
        #expect(error == nil)
    }
}
