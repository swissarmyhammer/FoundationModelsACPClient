import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Testing

// The integration tests of `SAHGraphQLClient` over a real ACP connection to
// the real GraphQL tunnel (`GraphQLTunnel`) of FoundationModelsACPAgent.
//
// The agent is `RoutedACPAgent` in the `graphql-tunnel-server` process, over
// its stdio. It uses the stub model path, so it loads no model. A host tool
// gives each session the small `probe` endpoint of that server (the
// `ProbeEndpoint` of the `LiveAgentServer` package):
//
// - `execute` gives `{"data":{"echo":<the variables>}}`.
// - `subscribe` gives `{"data":{"event":1}}` and the next numbers, as many as
//   the `events` variable tells, and then ends, unless `holds` is `true`.
// - `subscribe` with `watchesCancellations` gives `{"data":{"watching":true}}`
//   and then `{"data":{"cancelled":true}}` each time the server cancels
//   another stream of the endpoint.
//
// Another host tool gives the `kanban` endpoint (`KanbanGraph`) over the
// board of the workspace. The kanban tests reach it as a `GraphQLEndpoint`
// with `SAHGraphQLClient.endpoint(named:sessionId:)`.
//
// The tests use the public API of the library only. No wait reads a clock or
// polls: each wait reads a stream, and the close of the connection ends each
// stream.

/// The prefix of the name of the temporary directory of each test.
private let temporaryDirectoryPrefix = "acp-client-graphql-integration"

/// The client name that each test gives in `initialize`.
private let clientName = "acp-client-graphql-integration-test"

/// The name of the endpoint of the server.
private let probeEndpoint = "probe"

/// The document of each probe call. The probe endpoint does not read it.
private let probeDocument = "{ probe }"

/// The name of the kanban endpoint of the server.
private let kanbanEndpoint = "kanban"

/// The mutation that makes the board of the session, with the name `Work`.
private let initBoardDocument = #"mutation { initBoard(input: {name: "Work"}) { id } }"#

/// The first event of a watching stream.
private let watchingEvent: JSONValue = .object(["data": .object(["watching": .bool(true)])])

/// The event of a watching stream when the server cancels another stream.
private let cancelledEvent: JSONValue = .object(["data": .object(["cancelled": .bool(true)])])

/// The `graphql-tunnel-server` process, and a connection model with one open
/// session on it.
@MainActor
private struct TunnelAgent {
    /// The temporary directory of the test.
    let root: URL

    /// The server process.
    let process: AgentProcess

    /// The connection model of the client side.
    let model: ConnectionModel

    /// The session that each probe call names: the probe endpoint reads the
    /// folder of a session.
    let sessionId: SessionId

    /// The client under test, over ``model``.
    var client: SAHGraphQLClient {
        SAHGraphQLClient(connection: model)
    }

    /// Builds and starts the server, connects a model to it, initializes the
    /// connection and opens one session.
    ///
    /// - Returns: The running agent. Call ``stop()`` in a `defer` right after
    ///   the call, so the close runs also when the test body throws.
    /// - Throws: The error of the build, of the start, or of a request.
    ///   Before it throws, the call stops what it started.
    static func start() async throws -> TunnelAgent {
        let root = try IntegrationTemporaryDirectory.make(prefix: temporaryDirectoryPrefix)
        let (process, workspace) = try await startProcess(in: root)
        let model = ConnectionModel(coalescingCadence: .zero)
        _ = await model.connect(over: process.transport)
        do {
            _ = try await model.initialize(.integrationTest(clientName: clientName))
            let session = try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
            return TunnelAgent(root: root, process: process, model: model, sessionId: session.id)
        } catch {
            await model.disconnect()
            process.shutdown()
            throw error
        }
    }

    /// Makes the workspace in a temporary directory, and builds and starts
    /// the server over it. No connection is on the process yet.
    ///
    /// - Parameter root: The temporary directory of the test.
    /// - Returns: The server process, and the workspace of its sessions.
    /// - Throws: The error of the directory creation, of the build, or of the
    ///   start of the process.
    static func startProcess(in root: URL) async throws -> (process: AgentProcess, workspace: URL) {
        let workspace = try IntegrationTemporaryDirectory.makeWorkspace(in: root)
        let process = try await LiveAgentServerBuild(rootDirectory: root)
            .startServer(LiveAgentServerBuild.graphQLTunnelServer, workspace: workspace)
        return (process, workspace)
    }

    /// Closes the connection, stops the server process, and removes the
    /// temporary directory.
    func stop() async {
        await model.disconnect()
        process.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    /// Starts one subscription on the probe endpoint.
    ///
    /// - Parameter variables: The variables of the subscription.
    /// - Returns: The stream of the subscription.
    func subscribeToProbe(_ variables: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, any Error> {
        client.subscribe(endpoint: probeEndpoint, sessionId: sessionId, document: probeDocument, variables: variables)
    }
}

/// One raw `initialize` exchange on the stdio of a server, with no connection
/// model. The test writes the request frame itself, so the frame can be in
/// the pipe before the agent sets its role.
private enum RawInitialize {
    /// The JSON-RPC id of the request.
    static let requestId: JSONValue = .number(1)

    /// One JSON-RPC request frame of the `initialize` method.
    private struct RequestFrame: Encodable {
        /// The JSON-RPC version.
        let jsonrpc: String

        /// The id of the request.
        let id: JSONValue

        /// The method name.
        let method: String

        /// The params of the request.
        let params: InitializeRequest
    }

    /// A response frame with the id of the request that has no `result`.
    struct MissingResult: Error, CustomStringConvertible {
        /// The response frame.
        let frame: JSONValue

        /// The response frame, as the reason of the failure.
        var description: String {
            "the initialize response has no result: \(frame)"
        }
    }

    /// Encodes the request frame, with the `initialize` request of an
    /// integration test.
    ///
    /// - Returns: The NDJSON frame.
    /// - Throws: An encoding failure.
    static func makeRequestFrame() throws -> Data {
        try NDJSONCodec.encode(
            RequestFrame(
                jsonrpc: "2.0", id: requestId, method: "initialize",
                params: .integrationTest(clientName: clientName)))
    }

    /// Reads the frames of a transport until the response to the request
    /// comes, and decodes its result.
    ///
    /// - Parameter transport: The transport of the server process.
    /// - Returns: The decoded result, or `nil` when the frames end with no
    ///   response.
    /// - Throws: ``MissingResult`` for an error response, the error of the
    ///   transport, or a decoding failure.
    static func response(from transport: any ACPTransport) async throws -> InitializeResponse? {
        for try await frame in NDJSONCodec.frames(from: transport.bytes, logger: .disabled) {
            guard case .message(.object(let message)) = frame, message["id"] == requestId else {
                continue
            }
            guard let result = message["result"] else {
                throw MissingResult(frame: .object(message))
            }
            return try JSONDecoder().decode(InitializeResponse.self, from: JSONEncoder().encode(result))
        }
        return nil
    }
}

/// Reads each element of a stream until it ends.
///
/// This function is a copy of `AsyncThrowingStream.collect()` in
/// `Tests/FoundationModelsACPClientTests/AsyncThrowingStreamCollection.swift`
/// of the root package. If you change one copy, change the other copy also.
/// The two test targets cannot share one function. This package gets only the
/// library product and the ACP wire from the root package, and a test target
/// cannot be a dependency of another package. A shared function must thus go
/// into the library as public API, or into a new test-support product. The
/// library does not keep test helpers, and a new product changes the package
/// boundary. Thus each test target keeps its own copy.
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

/// Reads the next element of a stream.
///
/// - Parameter iterator: The iterator of the stream.
/// - Returns: The element, `nil` at the normal finish, or the error that
///   ended the stream.
private func nextResult(
    of iterator: inout AsyncThrowingStream<JSONValue, any Error>.AsyncIterator
) async -> Result<JSONValue?, any Error> {
    do {
        return .success(try await iterator.next())
    } catch {
        return .failure(error)
    }
}

/// The error that ended a stream, from the result of one read.
///
/// - Parameter result: The result of the read.
/// - Returns: The error, or `nil` for an element or a normal finish.
private func endingError(of result: Result<JSONValue?, any Error>) -> (any Error)? {
    guard case .failure(let error) = result else {
        return nil
    }
    return error
}

/// The `extensions.code` of each GraphQL error that a stream threw with
/// ``SAHGraphQLError/graphQL(_:)``.
///
/// - Parameter error: The error that ended the stream, or `nil`.
/// - Returns: The codes, in order; an error with no code gives no entry.
///   `nil` when the stream did not end with a GraphQL error.
private func graphQLErrorCodes(of error: (any Error)?) -> [String]? {
    guard case .graphQL(.array(let items))? = error as? SAHGraphQLError else {
        return nil
    }
    return codes(of: items)
}

/// The `extensions.code` of each GraphQL error of a JSON response text.
///
/// - Parameter text: The JSON text of the response.
/// - Returns: The codes, in order; an error with no code gives no entry.
private func graphQLErrorCodes(inResponse text: String) -> [String] {
    guard case .object(let response)? = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
        case .array(let items)? = response["errors"]
    else {
        return []
    }
    return codes(of: items)
}

/// The `extensions.code` of each GraphQL error of an `errors` array.
///
/// - Parameter items: The GraphQL errors.
/// - Returns: The codes, in order; an error with no code gives no entry.
private func codes(of items: [JSONValue]) -> [String] {
    items.compactMap { item in
        guard case .object(let error) = item,
            case .object(let extensions)? = error["extensions"],
            case .string(let code)? = extensions["code"]
        else {
            return nil
        }
        return code
    }
}

/// Reads one string at a path of keys in a JSON response text.
///
/// - Parameters:
///   - keys: The keys from the top object down.
///   - text: The JSON text of the response.
/// - Returns: The string, or `nil` when the path has no string.
private func string(at keys: [String], inResponse text: String) -> String? {
    var value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    for key in keys {
        guard case .object(let object)? = value else {
            return nil
        }
        value = object[key]
    }
    guard case .string(let string)? = value else {
        return nil
    }
    return string
}

@MainActor
@Suite("SAHGraphQLClient against the GraphQL tunnel of a real agent")
struct GraphQLTunnelTests {
    @Test func executeReachesTheProbeEndpointThroughTheTunnel() async throws {
        let agent = try await TunnelAgent.start()
        defer { await agent.stop() }

        let result = try await agent.client.execute(
            endpoint: probeEndpoint, sessionId: agent.sessionId, document: probeDocument,
            variables: ["word": .string("hello")])

        #expect(result == .object(["data": .object(["echo": .object(["word": .string("hello")])])]))
    }

    @Test func endpointsListsTheProbeEndpointWithItsScope() async throws {
        let agent = try await TunnelAgent.start()
        defer { await agent.stop() }

        let endpoints = try await agent.client.endpoints()

        let probe = try #require(endpoints.first { $0.name == probeEndpoint })
        #expect(probe.scope == .sessionFolder)
        #expect(probe.version == "1")
    }

    @Test func subscribeGivesEachEventAndFinishesNormallyAtComplete() async throws {
        let agent = try await TunnelAgent.start()
        defer { await agent.stop() }
        let eventCount = 3

        let (elements, error) = await collect(agent.subscribeToProbe(["events": .number(Double(eventCount))]))

        let expected: [JSONValue] = (0..<eventCount).map { index in
            .object(["data": .object(["event": .number(Double(index + 1))])])
        }
        #expect(elements == expected)
        #expect(error == nil)
    }

    @Test func subscribeToAnUnknownEndpointThrowsTheGraphQLErrorOfTheServer() async throws {
        let agent = try await TunnelAgent.start()
        defer { await agent.stop() }

        let (elements, error) = await collect(
            agent.client.subscribe(endpoint: "noSuchEndpoint", sessionId: agent.sessionId, document: probeDocument))

        #expect(elements.isEmpty)
        #expect(graphQLErrorCodes(of: error) == ["UNKNOWN_ENDPOINT"])
    }

    @Test func aStoppedIterationStopsTheSubscriptionOnTheServer() async throws {
        let agent = try await TunnelAgent.start()
        defer { await agent.stop() }
        var watcher = agent.subscribeToProbe(["watchesCancellations": .bool(true)]).makeAsyncIterator()
        let watching = await nextResult(of: &watcher)
        #expect(try watching.get() == watchingEvent)

        // The caller reads one event of a held subscription, and then its
        // task stops the iteration.
        let held = agent.subscribeToProbe(["events": .number(1), "holds": .bool(true)])
        let (firstEvents, firstContinuation) = AsyncStream<JSONValue>.makeStream()
        let reading = Task {
            for try await event in held {
                firstContinuation.yield(event)
            }
        }
        var firstIterator = firstEvents.makeAsyncIterator()
        #expect(await firstIterator.next() != nil)
        reading.cancel()
        firstContinuation.finish()

        // The server cancels the held stream when the unsubscribe comes, and
        // the watcher then gives its event. The close of the connection also
        // ends this wait. No other event tells that the unsubscribe will
        // never come, so this wait is a known limit of rule T1: it hangs when
        // the client sends no unsubscribe.
        let cancelled = await nextResult(of: &watcher)
        #expect(try cancelled.get() == cancelledEvent)
    }

    @Test func aClosedConnectionThrowsConnectionClosed() async throws {
        let agent = try await TunnelAgent.start()
        defer { await agent.stop() }
        var held = agent.subscribeToProbe(["events": .number(1), "holds": .bool(true)]).makeAsyncIterator()
        let first = await nextResult(of: &held)
        #expect(try first.get() != nil)

        await agent.model.disconnect()

        let ending = await nextResult(of: &held)
        #expect(endingError(of: ending) as? SAHGraphQLError == .connectionClosed)
    }

    // MARK: - The start-up of the server

    // The test writes `initialize` into the stdin of the server immediately
    // after the process starts, before the agent can set its role. The
    // agent must serve that frame, and must not answer `methodNotFound`. A
    // subprocess cannot make this order deterministic, so this check can
    // pass also when the defect is present. The deterministic test is
    // `InboundBeforeRoleTests` of FoundationModelsACP.
    @Test func anInitializeWrittenAtTheProcessStartGetsAnInitializeResponse() async throws {
        let root = try IntegrationTemporaryDirectory.make(prefix: temporaryDirectoryPrefix)
        defer { try? FileManager.default.removeItem(at: root) }
        let (process, _) = try await TunnelAgent.startProcess(in: root)
        defer { process.shutdown() }

        try await process.transport.write(RawInitialize.makeRequestFrame())
        let response = try #require(try await RawInitialize.response(from: process.transport))

        #expect(response.protocolVersion == ACPClient.supportedProtocolVersion)
    }

    // MARK: - The kanban endpoint as a GraphQLEndpoint

    @Test func anUnknownEndpointNameThrowsUnknownEndpoint() async throws {
        let agent = try await TunnelAgent.start()
        defer { await agent.stop() }

        await #expect(throws: SAHGraphQLEndpointError.unknownEndpoint(name: "noSuchEndpoint")) {
            try await agent.client.endpoint(named: "noSuchEndpoint", sessionId: agent.sessionId)
        }
    }

    // The agent gives the trust `userDevice` to a connection with no
    // connection header, as this stdio connection is. Only an HTTP
    // connection with no device token is `external`, so this test cannot
    // check `UNREACHABLE_BOARD`. `SAHGraphQLEndpointTests` of the unit tests
    // checks it with an agent that gives an `external` viewer.
    @Test func theKanbanEndpointReadsAndWritesTheBoardOfItsSession() async throws {
        let agent = try await TunnelAgent.start()
        defer { await agent.stop() }
        let kanban = try await agent.client.endpoint(named: kanbanEndpoint, sessionId: agent.sessionId)

        let made = try await kanban.execute(query: initBoardDocument, variables: [:], operationName: nil, viewer: nil)
        let own = try await kanban.execute(query: "{ board { name } }", variables: [:], operationName: nil, viewer: nil)

        #expect(graphQLErrorCodes(inResponse: made) == [], "\(made)")
        #expect(own == #"{"data":{"board":{"name":"Work"}}}"#)
    }

    @Test func aKanbanMutationGivesOneSubscriptionEvent() async throws {
        let agent = try await TunnelAgent.start()
        defer { await agent.stop() }
        let kanban = try await agent.client.endpoint(named: kanbanEndpoint, sessionId: agent.sessionId)
        _ = try await kanban.execute(query: initBoardDocument, variables: [:], operationName: nil, viewer: nil)
        let read = try await kanban.execute(query: "{ board { cursor } }", variables: [:], operationName: nil, viewer: nil)
        let cursor = try #require(string(at: ["data", "board", "cursor"], inResponse: read), "\(read)")

        let added = try await kanban.execute(
            query: #"mutation { addTask(input: {title: "Write the tests"}) { id } }"#, variables: [:],
            operationName: nil, viewer: nil)
        let addedId = try #require(string(at: ["data", "addTask", "id"], inResponse: added), "\(added)")
        // The subscription starts from the cursor before the mutation, so its
        // first event is the change of the mutation, with no race.
        var changes = try await kanban.subscribe(
            query: #"subscription { changes(after: "\#(cursor)") { updates { id } } }"#, variables: [:],
            operationName: nil, viewer: nil
        ).makeAsyncIterator()
        let event = try #require(try await changes.next())

        #expect(event.contains(addedId), "\(event)")
        #expect(graphQLErrorCodes(inResponse: event) == [], "\(event)")
    }
}
