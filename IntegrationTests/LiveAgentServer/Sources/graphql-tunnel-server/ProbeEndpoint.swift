import Foundation
import FoundationModels
import FoundationModelsExtras
import GraphQL
import Synchronization

/// The variables that the probe endpoint reads from a subscription.
private struct ProbeSubscription: Decodable {
    /// The count of events that the stream gives, numbered from 1.
    var events: Int?

    /// Whether the stream stays open after its events.
    var holds: Bool?

    /// Whether the stream watches the cancellations of the other streams,
    /// in place of its own events.
    var watchesCancellations: Bool?
}

/// The streams that watch the cancellation of each other subscription
/// stream of the probe endpoint.
private final class CancellationWatchers: Sendable {
    /// The continuation of each watching stream.
    private let watchers = Mutex<[UUID: AsyncThrowingStream<String, Error>.Continuation]>([:])

    /// Adds one watching stream. Its first event tells that it watches.
    ///
    /// - Returns: The stream.
    func watch() -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let key = UUID()
        watchers.withLock { $0[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.watchers.withLock { _ = $0.removeValue(forKey: key) }
        }
        continuation.yield(ProbeEndpoint.watchingEventText)
        return stream
    }

    /// Gives one event to each watching stream: a stream was cancelled.
    func streamWasCancelled() {
        for continuation in watchers.withLock({ Array($0.values) }) {
            continuation.yield(ProbeEndpoint.cancelledEventText)
        }
    }
}

/// The small GraphQL endpoint of the integration test of the GraphQL tunnel.
///
/// It runs no GraphQL engine, because the test checks the tunnel and the
/// client, and not a schema:
///
/// - `execute` gives `{"data":{"echo":<the variables>}}`.
/// - `subscribe` gives the events `{"data":{"event":1}}`, `{"data":{"event":2}}`
///   and so on, as many as the `events` variable tells. The stream then
///   ends, unless the `holds` variable is `true`.
/// - `subscribe` with the `watchesCancellations` variable `true` gives
///   `{"data":{"watching":true}}` at once, and then
///   `{"data":{"cancelled":true}}` each time the server cancels another
///   stream of this endpoint, for example at `_sah/graphql/unsubscribe`.
struct ProbeEndpoint: GraphQLEndpoint {
    /// The JSON text of the first event of a watching stream.
    static let watchingEventText = #"{"data":{"watching":true}}"#

    /// The JSON text of the event of a cancelled stream.
    static let cancelledEventText = #"{"data":{"cancelled":true}}"#

    /// The name that the test calls.
    let name = "probe"

    /// The version of the schema.
    let version = "1"

    /// The session of a call selects the folder, so the call needs a session.
    let scope = GraphQLEndpointScope.sessionFolder

    /// The SDL of the schema.
    let schema = "type Query { echo: String } type Subscription { event: Int }"

    /// The streams that watch the cancellations.
    private let watchers = CancellationWatchers()

    func execute(
        query _: String, variables: [String: Map], operationName _: String?, viewer _: GraphQLViewer?
    ) async throws -> String {
        let echo = try String(decoding: JSONEncoder().encode(variables), as: UTF8.self)
        return #"{"data":{"echo":"# + echo + "}}"
    }

    func subscribe(
        query _: String, variables: [String: Map], operationName _: String?, viewer _: GraphQLViewer?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let options = try JSONDecoder().decode(ProbeSubscription.self, from: JSONEncoder().encode(variables))
        if options.watchesCancellations == true {
            return watchers.watch()
        }
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let watchers = watchers
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                watchers.streamWasCancelled()
            }
        }
        for index in 0..<max(options.events ?? 0, 0) {
            continuation.yield(#"{"data":{"event":\#(index + 1)}}"#)
        }
        if options.holds != true {
            continuation.finish()
        }
        return stream
    }
}

/// A host tool that gives the probe endpoint, as a top-level tool of each
/// session.
struct ProbeTool: GraphQLEndpointTool {
    /// The wire arguments; the tool reads nothing from them.
    @Generable
    struct Arguments {}

    let name = "graphql_probe"

    let description = "a host tool that gives the GraphQL probe endpoint of the integration test"

    /// The probe endpoint.
    let graphQLEndpoints: [any GraphQLEndpoint] = [ProbeEndpoint()]

    /// The model never calls the probe tool.
    func call(arguments _: Arguments) async throws -> String {
        ""
    }
}
