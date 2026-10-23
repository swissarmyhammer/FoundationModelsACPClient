import FoundationModelsACP

/// The client side of the SAH GraphQL tunnel (ACPC-6).
///
/// The client models of an app read the server state through this type. It
/// sends a GraphQL document string, its variables and its operation name to
/// one named endpoint of the server, and it gives the JSON result. It does not
/// parse GraphQL, and it does not link a GraphQL engine (D79).
///
/// Make it over the ACP connection of a ``ConnectionModel``
/// (``init(connection:)``), which sends the `_sah/graphql/*` messages to the
/// agent. Make it with a stub handler (``init(stub:)``) for the Step 0 stubs
/// of an app, for previews and for tests: the stub handler answers with
/// sample JSON. The calls of this type are the same for the two
/// initializers, so the client models and the views do not change when the
/// stub handler changes to the ACP connection.
public final class SAHGraphQLClient: Sendable {
    /// One GraphQL operation for one endpoint of the server.
    public struct Request: Hashable, Sendable {
        /// The name of the endpoint, for example `kanban`.
        public var endpoint: String

        /// The session that selects the data of the endpoint, or `nil` for no
        /// session. For an endpoint with the session folder as its scope, the
        /// folder of this session selects the data, and the server refuses a
        /// call with no session. An endpoint with the server as its scope
        /// accepts a call with no session. The client sends the value that
        /// the caller gives, and does not check it.
        public var sessionId: SessionId?

        /// The GraphQL document.
        public var document: String

        /// The variables of the operation.
        public var variables: [String: JSONValue]

        /// The operation in the document to run, or `nil` when the document
        /// has only one operation.
        public var operationName: String?

        /// Makes a request.
        ///
        /// - Parameters:
        ///   - endpoint: The name of the endpoint.
        ///   - sessionId: The session that selects the data of the endpoint,
        ///     or `nil` for no session.
        ///   - document: The GraphQL document.
        ///   - variables: The variables of the operation.
        ///   - operationName: The operation in the document to run.
        public init(
            endpoint: String,
            sessionId: SessionId?,
            document: String,
            variables: [String: JSONValue] = [:],
            operationName: String? = nil
        ) {
            self.endpoint = endpoint
            self.sessionId = sessionId
            self.document = document
            self.variables = variables
            self.operationName = operationName
        }
    }

    /// One endpoint that the server gives.
    public struct Endpoint: Hashable, Sendable {
        /// What selects the data of an endpoint.
        public enum Scope: Hashable, Sendable {
            /// The folder of the session of a request selects the data.
            case sessionFolder

            /// The endpoint has one set of data for the whole server.
            case server
        }

        /// The name of the endpoint, for example `kanban`.
        public var name: String

        /// The version of the schema of the endpoint.
        public var version: String

        /// The scope of the data of the endpoint.
        public var scope: Scope

        /// The schema of the endpoint, in SDL.
        public var schema: String

        /// Makes an endpoint.
        ///
        /// - Parameters:
        ///   - name: The name of the endpoint.
        ///   - version: The version of the schema.
        ///   - scope: The scope of the data.
        ///   - schema: The schema, in SDL.
        public init(name: String, version: String, scope: Scope, schema: String) {
            self.name = name
            self.version = version
            self.scope = scope
            self.schema = schema
        }
    }

    /// The place that answers each call: a stub handler or an ACP
    /// connection.
    private let backend: any SAHGraphQLBackend

    /// Makes a client that sends each call over the ACP connection of a
    /// connection model.
    ///
    /// Each call uses the connection that is open when the call starts, so
    /// the client keeps working after the host connects the model again. The
    /// model serves the `_sah/graphql/next`, `_sah/graphql/complete` and
    /// `_sah/graphql/error` notifications of the agent for each subscription
    /// of the client. A call with no open connection throws
    /// ``SAHGraphQLError/connectionClosed``.
    ///
    /// - Parameter connection: The connection model whose connection carries
    ///   each call.
    public init(connection: ConnectionModel) {
        backend = ConnectionGraphQLBackend(model: connection)
    }

    /// Makes a client that sends each call to a stub handler, and not to an
    /// ACP connection.
    ///
    /// - Parameter stub: The handler that answers each call with sample
    ///   JSON.
    public init(stub: some SAHGraphQLStubHandler) {
        backend = StubGraphQLBackend(stub: stub)
    }

    /// Runs a query or a mutation (`_sah/graphql/execute`).
    ///
    /// - Parameters:
    ///   - endpoint: The name of the endpoint.
    ///   - sessionId: The session that selects the data of the endpoint, or
    ///     `nil` for no session. See ``Request/sessionId``.
    ///   - document: The GraphQL document.
    ///   - variables: The variables of the operation.
    ///   - operationName: The operation in the document to run.
    /// - Returns: The GraphQL result, with its `data` and `errors` members as
    ///   the server sends them. A GraphQL error in `errors` does not throw.
    /// - Throws: ``SAHGraphQLError/connectionClosed`` when no connection is
    ///   open or the connection closes before the result, a `RequestError`
    ///   when the agent refuses the request, or an error of the stub handler.
    public func execute(
        endpoint: String,
        sessionId: SessionId?,
        document: String,
        variables: [String: JSONValue] = [:],
        operationName: String? = nil
    ) async throws -> JSONValue {
        try await backend.execute(
            Request(
                endpoint: endpoint,
                sessionId: sessionId,
                document: document,
                variables: variables,
                operationName: operationName
            )
        )
    }

    /// Starts a subscription (`_sah/graphql/subscribe`).
    ///
    /// Each element is one GraphQL result of `_sah/graphql/next`, in the
    /// order that the server sends them. The client gives each new
    /// subscription its own subscription id, and reads only the
    /// notifications of that id.
    ///
    /// The rule for the end of the stream:
    ///
    /// - `_sah/graphql/complete` finishes the stream normally. The iteration
    ///   ends, and nothing throws.
    /// - `_sah/graphql/error` throws ``SAHGraphQLError/graphQL(_:)`` with the
    ///   `errors` array that the server sent.
    /// - A closed connection throws ``SAHGraphQLError/connectionClosed``. A
    ///   subscribe with no open connection throws it too.
    /// - A refused `_sah/graphql/subscribe` request throws the
    ///   `RequestError` of the agent.
    /// - The client does not subscribe again by itself, after each of these
    ///   ends. The client model decides when to resume, and from which
    ///   cursor.
    /// - When the caller stops the iteration of the stream (its task is
    ///   cancelled, or the stream is released), the client sends
    ///   `_sah/graphql/unsubscribe` for the subscription id. It sends it
    ///   after the answer to `_sah/graphql/subscribe`, so the server stops a
    ///   subscription that it started. After the end of the stream, the
    ///   client sends no unsubscribe.
    ///
    /// - Parameters:
    ///   - endpoint: The name of the endpoint.
    ///   - sessionId: The session that selects the data of the endpoint.
    ///   - document: The GraphQL document.
    ///   - variables: The variables of the operation.
    ///   - operationName: The operation in the document to run.
    /// - Returns: The stream of the GraphQL results.
    public func subscribe(
        endpoint: String,
        sessionId: SessionId?,
        document: String,
        variables: [String: JSONValue] = [:],
        operationName: String? = nil
    ) -> AsyncThrowingStream<JSONValue, any Error> {
        backend.subscribe(
            Request(
                endpoint: endpoint,
                sessionId: sessionId,
                document: document,
                variables: variables,
                operationName: operationName
            )
        )
    }

    /// Lists the endpoints of the server (`_sah/graphql/endpoints`).
    ///
    /// Over an ACP connection, the list leaves out each endpoint whose scope
    /// the client does not know, and the connection logs one diagnostic for
    /// it.
    ///
    /// - Returns: The endpoints.
    /// - Throws: ``SAHGraphQLError/connectionClosed`` when no connection is
    ///   open or the connection closes before the list, a `RequestError` when
    ///   the agent refuses the request, or an error of the stub handler.
    public func endpoints() async throws -> [Endpoint] {
        try await backend.endpoints()
    }
}
