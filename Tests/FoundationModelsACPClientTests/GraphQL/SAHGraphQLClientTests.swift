import FoundationModelsACP
import Synchronization
import Testing

import FoundationModelsACPClient

// The tests of `SAHGraphQLClient` on a stub handler. Each test uses only the
// public API, as the Step 0 stubs of an app do.

/// The session of each request.
private let sessionId = SessionId(rawValue: "session-1")

/// The document of each request.
private let boardQuery = "query Board($id: ID!) { board(id: $id) { name } }"

/// A stub handler that keeps each request and answers with fixed JSON.
private final class RecordingStubHandler: SAHGraphQLStubHandler {
    /// The result of each `execute`.
    let result: JSONValue

    /// The elements of each subscription. The subscription stays open after
    /// them.
    let events: [JSONValue]

    /// The endpoints of `endpoints`.
    let endpointList: [SAHGraphQLClient.Endpoint]

    /// Each request that the handler got.
    let requests = Mutex<[SAHGraphQLClient.Request]>([])

    /// Gets one element when a subscription stream terminates.
    let terminations: AsyncStream<Void>

    /// The continuation of ``terminations``.
    private let terminationContinuation: AsyncStream<Void>.Continuation

    init(
        result: JSONValue = .null,
        events: [JSONValue] = [],
        endpointList: [SAHGraphQLClient.Endpoint] = []
    ) {
        self.result = result
        self.events = events
        self.endpointList = endpointList
        (terminations, terminationContinuation) = AsyncStream<Void>.makeStream()
    }

    func execute(_ request: SAHGraphQLClient.Request) async throws -> JSONValue {
        requests.withLock { $0.append(request) }
        return result
    }

    func subscribe(_ request: SAHGraphQLClient.Request) -> AsyncThrowingStream<JSONValue, any Error> {
        requests.withLock { $0.append(request) }
        let (stream, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        let terminationContinuation = terminationContinuation
        continuation.onTermination = { _ in terminationContinuation.yield() }
        for event in events {
            continuation.yield(event)
        }
        return stream
    }

    func endpoints() async throws -> [SAHGraphQLClient.Endpoint] {
        endpointList
    }
}

/// A stub handler whose subscriptions give their events and then end.
private final class EndingStubHandler: SAHGraphQLStubHandler {
    /// The elements of each subscription.
    let events: [JSONValue]

    /// The error that ends each subscription, or `nil` for a completion.
    let endError: SAHGraphQLError?

    init(events: [JSONValue], endError: SAHGraphQLError?) {
        self.events = events
        self.endError = endError
    }

    func execute(_ request: SAHGraphQLClient.Request) async throws -> JSONValue {
        throw SAHGraphQLError.connectionClosed
    }

    func subscribe(_ request: SAHGraphQLClient.Request) -> AsyncThrowingStream<JSONValue, any Error> {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        for event in events {
            continuation.yield(event)
        }
        continuation.finish(throwing: endError)
        return stream
    }

    func endpoints() async throws -> [SAHGraphQLClient.Endpoint] {
        throw SAHGraphQLError.connectionClosed
    }
}

/// Reads each element of a stream until it ends.
///
/// - Parameter stream: The stream.
/// - Returns: The elements, and the error that ended the stream, or `nil` for
///   a completion.
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

@Suite("SAHGraphQLClient on a stub handler")
struct SAHGraphQLClientTests {
    @Test func executeSendsTheWholeRequestToTheHandlerAndGivesItsResult() async throws {
        let result: JSONValue = .object(["data": .object(["board": .object(["name": .string("Work")])])])
        let handler = RecordingStubHandler(result: result)
        let client = SAHGraphQLClient(stub: handler)

        let answer = try await client.execute(
            endpoint: "kanban",
            sessionId: sessionId,
            document: boardQuery,
            variables: ["id": .string("board-1")],
            operationName: "Board"
        )

        #expect(answer == result)
        let expected = SAHGraphQLClient.Request(
            endpoint: "kanban",
            sessionId: sessionId,
            document: boardQuery,
            variables: ["id": .string("board-1")],
            operationName: "Board"
        )
        #expect(handler.requests.withLock { $0 } == [expected])
    }

    @Test func executeWithNoSessionSendsNoSessionToTheHandler() async throws {
        let handler = RecordingStubHandler(result: .object(["data": .null]))
        let client = SAHGraphQLClient(stub: handler)

        _ = try await client.execute(endpoint: "settings", sessionId: nil, document: "query { settings }")

        let expected = SAHGraphQLClient.Request(endpoint: "settings", sessionId: nil, document: "query { settings }")
        #expect(handler.requests.withLock { $0 } == [expected])
    }

    @Test func executeGivesAGraphQLErrorInTheResultWithNoThrow() async throws {
        let result: JSONValue = .object([
            "data": .null,
            "errors": .array([.object(["message": .string("No board")])]),
        ])
        let client = SAHGraphQLClient(stub: RecordingStubHandler(result: result))

        let answer = try await client.execute(endpoint: "kanban", sessionId: sessionId, document: boardQuery)

        #expect(answer == result)
    }

    @Test func executeGivesTheErrorOfTheHandler() async {
        let client = SAHGraphQLClient(stub: EndingStubHandler(events: [], endError: nil))

        await #expect(throws: SAHGraphQLError.connectionClosed) {
            try await client.execute(endpoint: "kanban", sessionId: sessionId, document: boardQuery)
        }
    }

    @Test func subscribeGivesEachResultAndEndsAtCompletion() async {
        let events: [JSONValue] = [.object(["data": .number(1)]), .object(["data": .number(2)])]
        let client = SAHGraphQLClient(stub: EndingStubHandler(events: events, endError: nil))

        let (elements, error) = await collect(
            client.subscribe(endpoint: "kanban", sessionId: sessionId, document: "subscription { changes }")
        )

        #expect(elements == events)
        #expect(error == nil)
    }

    @Test(arguments: [
        SAHGraphQLError.graphQL(.array([.object(["extensions": .object(["code": .string("CURSOR_EXPIRED")])])])),
        SAHGraphQLError.connectionClosed,
    ])
    func subscribeThrowsTheTypedErrorThatEndsTheSubscription(endError: SAHGraphQLError) async {
        let events: [JSONValue] = [.object(["data": .number(1)])]
        let client = SAHGraphQLClient(stub: EndingStubHandler(events: events, endError: endError))

        let (elements, error) = await collect(
            client.subscribe(endpoint: "kanban", sessionId: sessionId, document: "subscription { changes }")
        )

        #expect(elements == events)
        #expect(error as? SAHGraphQLError == endError)
    }

    @Test func aStoppedIterationTerminatesTheSubscriptionOfTheHandler() async throws {
        let handler = RecordingStubHandler(events: [.object(["data": .number(1)])])
        let client = SAHGraphQLClient(stub: handler)
        let stream = client.subscribe(
            endpoint: "kanban",
            sessionId: sessionId,
            document: "subscription { changes }",
            variables: ["after": .string("cursor-7")]
        )

        // The caller reads one element, and then its task stops the
        // iteration.
        let (firstElements, firstContinuation) = AsyncStream<JSONValue>.makeStream()
        let reading = Task {
            for try await element in stream {
                firstContinuation.yield(element)
            }
        }
        var firstIterator = firstElements.makeAsyncIterator()
        #expect(await firstIterator.next() == .object(["data": .number(1)]))
        reading.cancel()

        // The wait ends on the termination of the stream of the handler.
        var terminations = handler.terminations.makeAsyncIterator()
        #expect(await terminations.next() != nil)
        firstContinuation.finish()
        #expect(handler.requests.withLock { $0.first?.variables } == ["after": .string("cursor-7")])
    }

    @Test func endpointsGivesTheListOfTheHandler() async throws {
        let endpoints = [
            SAHGraphQLClient.Endpoint(name: "kanban", version: "1", scope: .sessionFolder, schema: "type Query { x: Int }"),
            SAHGraphQLClient.Endpoint(name: "agents", version: "2", scope: .server, schema: "type Query { y: Int }"),
        ]
        let client = SAHGraphQLClient(stub: RecordingStubHandler(endpointList: endpoints))

        #expect(try await client.endpoints() == endpoints)
    }
}
