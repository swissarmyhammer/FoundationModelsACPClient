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
        let workspace = try IntegrationTemporaryDirectory.makeWorkspace(in: root)
        let process = try await LiveAgentServerBuild(rootDirectory: root)
            .startServer(LiveAgentServerBuild.graphQLTunnelServer, workspace: workspace)
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
    return items.compactMap { item in
        guard case .object(let error) = item,
            case .object(let extensions)? = error["extensions"],
            case .string(let code)? = extensions["code"]
        else {
            return nil
        }
        return code
    }
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
}
