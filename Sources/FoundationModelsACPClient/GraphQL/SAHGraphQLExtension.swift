import FoundationModelsACP
import Observation

/// The built-in extension that serves the SAH GraphQL tunnel of one
/// connection.
///
/// Its connection state holds the `_sah/graphql/subscribe` subscriptions of
/// the connection, and the SAH object in `_meta.sah` of the `initialize`
/// answer:
///
/// - ``registerHandlers(into:context:)`` registers the
///   `_sah/graphql/next`, `_sah/graphql/complete` and `_sah/graphql/error`
///   handlers of the subscriptions.
/// - ``didInitialize(_:state:)`` reads `_meta.sah`.
/// - ``didClose(state:)`` finishes each open subscription with
///   ``SAHGraphQLError/connectionClosed``.
///
/// ``ConnectionModel/sah``, ``ConnectionModel/graphQLEndpoints`` and the
/// backend of a ``SAHGraphQLClient`` over the model read the connection
/// state. The extension takes no session update.
///
/// The model makes a new extension for each connection, with the logger of
/// that connection and a new subscription table. The extension gives both
/// to the connection state that it makes. The notification handlers use the
/// table of the extension directly, so they do not hop to the main actor.
struct SAHGraphQLExtension: ClientModelExtension {
    /// The connection state of the extension: the GraphQL subscriptions and
    /// the SAH object of one connection.
    @MainActor @Observable
    final class ConnectionState {
        /// The open subscriptions of the connection. Each connection gets a
        /// new table, because a subscription id is unique only for one
        /// connection.
        ///
        /// The notification handlers read the table in the read loop of the
        /// connection, off the main actor, so the table has its own lock.
        nonisolated let subscriptions: SAHGraphQLSubscriptions

        /// The SAH object in `_meta.sah` of the last `initialize` answer of
        /// the connection, or `nil` when the agent has no SAH extensions.
        ///
        /// It is `nil` before the `initialize` answer, and when the answer
        /// has no valid `_meta.sah`.
        private(set) var sah: SAH.InitializeMeta?

        /// The GraphQL endpoints of ``sah``, in the form of the client. The
        /// list is empty when ``sah`` is `nil`. The list leaves out each
        /// endpoint whose scope the client does not know.
        private(set) var graphQLEndpoints: [SAHGraphQLClient.Endpoint] = []

        /// The diagnostic sink of the connection; never stdout.
        private let connectionLogger: ACPLogger

        /// Makes the state of a new connection, with no SAH object.
        ///
        /// - Parameters:
        ///   - subscriptions: The subscription table of the connection.
        ///   - connectionLogger: The diagnostic sink of the connection.
        init(subscriptions: SAHGraphQLSubscriptions, connectionLogger: ACPLogger) {
            self.subscriptions = subscriptions
            self.connectionLogger = connectionLogger
        }

        /// Keeps the SAH object in `_meta.sah` of an `initialize` answer,
        /// and its endpoints.
        ///
        /// When `_meta.sah` is present but is not a valid SAH object, the
        /// call logs one diagnostic. A `null` member is the same as no
        /// member. The call logs one diagnostic for each endpoint whose
        /// scope the client does not know.
        ///
        /// - Parameter response: The answer of the agent.
        func keepSAHObject(of response: InitializeResponse) {
            sah = sahObject(in: response)
            graphQLEndpoints = SAHGraphQLClient.Endpoint.clientEndpoints(
                of: sah?.graphql ?? [], logger: connectionLogger)
        }

        /// Gives the SAH object in `_meta.sah` of an `initialize` answer.
        ///
        /// - Parameter response: The answer of the agent.
        /// - Returns: The SAH object, or `nil` when the agent has no SAH
        ///   extensions. A `_meta.sah` that is not valid logs one diagnostic.
        private func sahObject(in response: InitializeResponse) -> SAH.InitializeMeta? {
            if let sah = SAH.InitializeMeta.extract(from: response.meta) {
                return sah
            }
            if case .object(let members)? = response.meta, let member = members[SAH.metaKey], member != .null {
                connectionLogger.log(
                    "ConnectionModel: the _meta.sah of the initialize response is not a valid SAH object, "
                        + "so the model uses no SAH extension of the agent"
                )
            }
            return nil
        }
    }

    /// The diagnostic sink of the connection of this extension; never
    /// stdout.
    let connectionLogger: ACPLogger

    /// The subscription table of the connection of this extension. The
    /// connection state holds the same table.
    let subscriptions = SAHGraphQLSubscriptions()

    @MainActor func makeConnectionState() -> ConnectionState {
        ConnectionState(subscriptions: subscriptions, connectionLogger: connectionLogger)
    }

    /// Registers the handlers of the `_sah/graphql/next`,
    /// `_sah/graphql/complete` and `_sah/graphql/error` notifications. The
    /// handlers give each notification to the subscription table of the
    /// connection, and do not hop to the main actor.
    ///
    /// - Parameters:
    ///   - handlers: The handlers of the connection.
    ///   - context: The context of the connection.
    func registerHandlers(
        into handlers: inout ClientModelExtensionHandlers,
        context: ClientModelExtensionContext<Self>
    ) {
        subscriptions.registerHandlers(into: &handlers)
    }

    /// Keeps the SAH object in `_meta.sah` of the answer.
    ///
    /// - Parameters:
    ///   - response: The `initialize` answer.
    ///   - state: The connection state.
    @MainActor func didInitialize(_ response: InitializeResponse, state: ConnectionState) {
        state.keepSAHObject(of: response)
    }

    /// Finishes each open subscription with
    /// ``SAHGraphQLError/connectionClosed``, and refuses each later
    /// subscription of the connection.
    ///
    /// - Parameter state: The connection state.
    @MainActor func didClose(state: ConnectionState) {
        state.subscriptions.closeAll()
    }
}
