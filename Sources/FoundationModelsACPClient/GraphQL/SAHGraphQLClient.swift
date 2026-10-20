import FoundationModelsACP

/// The client side of the SAH GraphQL tunnel (ACPC-6).
///
/// The client models of an app read the server state through this type. It
/// sends a GraphQL document string, its variables and its operation name to
/// one named endpoint of the server, and it gives the JSON result. It does not
/// parse GraphQL, and it does not link a GraphQL engine (D79).
///
/// Make it with a stub handler (``init(stub:)``). The stub handler answers
/// with sample JSON, for the Step 0 stubs of an app, for previews and for
/// tests. A later initializer makes the same type over an ACP connection,
/// which sends the `_sah/graphql/*` messages. The calls of this type do not
/// change when the stub handler changes to the ACP connection, so the client
/// models and the views do not change.
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

    /// The handler that answers each call.
    private let handler: any SAHGraphQLStubHandler

    /// Makes a client that sends each call to a stub handler, and not to an
    /// ACP connection.
    ///
    /// - Parameter stub: The handler that answers each call with sample
    ///   JSON.
    public init(stub: some SAHGraphQLStubHandler) {
        handler = stub
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
    /// - Throws: ``SAHGraphQLError/connectionClosed`` when the connection
    ///   closes before the result, or an error of the handler.
    public func execute(
        endpoint: String,
        sessionId: SessionId?,
        document: String,
        variables: [String: JSONValue] = [:],
        operationName: String? = nil
    ) async throws -> JSONValue {
        try await handler.execute(
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
    /// Each element is one GraphQL result of `_sah/graphql/next`. The stream
    /// ends at `_sah/graphql/complete`. It throws ``SAHGraphQLError/graphQL(_:)``
    /// at `_sah/graphql/error`, and ``SAHGraphQLError/connectionClosed`` when
    /// the connection closes. The client does not subscribe again by itself:
    /// the client model decides when to resume, and from which cursor. When
    /// the caller stops the iteration of the stream, the client stops the
    /// subscription (`_sah/graphql/unsubscribe`).
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
        handler.subscribe(
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
    /// - Returns: The endpoints.
    /// - Throws: ``SAHGraphQLError/connectionClosed`` when the connection
    ///   closes before the list, or an error of the handler.
    public func endpoints() async throws -> [Endpoint] {
        try await handler.endpoints()
    }
}
