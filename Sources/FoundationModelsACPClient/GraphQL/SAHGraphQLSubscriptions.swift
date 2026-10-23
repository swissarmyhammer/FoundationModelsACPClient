import FoundationModelsACP
import Synchronization

/// The open `_sah/graphql/subscribe` subscriptions of one ACP connection,
/// keyed by subscription id.
///
/// A subscription id is unique for each connection, so each connection of a
/// ``ConnectionModel`` gets a new table. The served `Client` of the
/// connection gives ``extensionHandlers`` to the connection. Thus each
/// `_sah/graphql/next`, `_sah/graphql/complete` and `_sah/graphql/error`
/// comes to this table, and the table gives it to the stream of its
/// subscription id:
///
/// - `next` gives its result to the stream.
/// - `complete` finishes the stream normally, and removes the subscription.
/// - `error` finishes the stream with ``SAHGraphQLError/graphQL(_:)``, and
///   removes the subscription.
///
/// A notification for an id with no open subscription changes nothing. The
/// agent can send one after the client stopped the subscription.
///
/// When the connection closes, ``closeAll()`` finishes each open stream with
/// ``SAHGraphQLError/connectionClosed``. After that, ``open(_:_:)`` refuses
/// each new subscription. A `Mutex` holds the table, because the
/// notification handlers run in the read loop of the connection and must
/// return at once.
final class SAHGraphQLSubscriptions: Sendable {
    /// The continuation of the stream of one subscription.
    typealias Continuation = AsyncThrowingStream<JSONValue, any Error>.Continuation

    /// The open subscriptions, and whether the connection closed.
    private struct State {
        /// The continuation of each open subscription, by subscription id.
        var open: [SAH.GraphQL.SubscriptionId: Continuation] = [:]

        /// Whether the connection closed.
        var isClosed = false
    }

    /// The table, under its lock.
    private let state = Mutex(State())

    /// The handlers of the three notifications of the server, for the served
    /// `Client` of the connection.
    var extensionHandlers: ExtensionHandlers {
        var handlers = ExtensionHandlers()
        handlers.registerNotification(SAH.GraphQL.Method.next, params: SAH.GraphQL.NextNotification.self) {
            self.deliver($0)
        }
        handlers.registerNotification(SAH.GraphQL.Method.complete, params: SAH.GraphQL.CompleteNotification.self) {
            self.remove($0.subscriptionId)?.finish()
        }
        handlers.registerNotification(SAH.GraphQL.Method.error, params: SAH.GraphQL.ErrorNotification.self) {
            self.remove($0.subscriptionId)?.finish(throwing: SAHGraphQLError.graphQL(.array($0.payload)))
        }
        return handlers
    }

    /// Opens one subscription, unless the connection closed.
    ///
    /// - Parameters:
    ///   - id: The subscription id.
    ///   - continuation: The continuation of the stream of the subscription.
    /// - Returns: `false` when the connection closed; then the table does not
    ///   keep the continuation.
    func open(_ id: SAH.GraphQL.SubscriptionId, _ continuation: Continuation) -> Bool {
        state.withLock { state in
            guard !state.isClosed else {
                return false
            }
            state.open[id] = continuation
            return true
        }
    }

    /// Removes one subscription.
    ///
    /// - Parameter id: The subscription id.
    /// - Returns: The continuation of the subscription, or `nil` when no
    ///   subscription with the id is open.
    @discardableResult
    func remove(_ id: SAH.GraphQL.SubscriptionId) -> Continuation? {
        state.withLock { $0.open.removeValue(forKey: id) }
    }

    /// Finishes the stream of each open subscription with
    /// ``SAHGraphQLError/connectionClosed``, and refuses each later
    /// ``open(_:_:)``. A second call does nothing.
    func closeAll() {
        let closed = state.withLock { state in
            state.isClosed = true
            let closing = Array(state.open.values)
            state.open.removeAll()
            return closing
        }
        for continuation in closed {
            continuation.finish(throwing: SAHGraphQLError.connectionClosed)
        }
    }

    /// Gives the result of one `_sah/graphql/next` to the stream of its
    /// subscription.
    ///
    /// - Parameter notification: The params of the notification.
    private func deliver(_ notification: SAH.GraphQL.NextNotification) {
        let continuation = state.withLock { $0.open[notification.subscriptionId] }
        continuation?.yield(notification.payload.jsonValue)
    }
}

extension SAH.GraphQL.ExecutionResult {
    /// The result as one JSON object, with the `data`, `errors` and
    /// `extensions` members that the result has. A member that the result
    /// does not have is not in the object.
    var jsonValue: JSONValue {
        var members: [String: JSONValue] = [:]
        members["data"] = data
        members["errors"] = errors.map(JSONValue.array)
        members["extensions"] = extensions
        return .object(members)
    }
}
