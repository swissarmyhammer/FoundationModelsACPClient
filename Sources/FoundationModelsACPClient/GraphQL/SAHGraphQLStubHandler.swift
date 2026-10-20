import FoundationModelsACP

/// The handler of a ``SAHGraphQLClient`` that is not on an ACP connection.
///
/// A stub handler answers each call with sample JSON. The Step 0 stubs of an
/// app, the previews and the tests give one to ``SAHGraphQLClient/init(stub:)``.
/// A client model reads only the ``SAHGraphQLClient``, so it does not change
/// when the stub handler changes to an ACP connection.
public protocol SAHGraphQLStubHandler: Sendable {
    /// Answers a query or a mutation.
    ///
    /// - Parameter request: The operation.
    /// - Returns: The GraphQL result, with its `data` and `errors` members.
    /// - Throws: An error, for example ``SAHGraphQLError/connectionClosed``
    ///   to show a lost connection.
    func execute(_ request: SAHGraphQLClient.Request) async throws -> JSONValue

    /// Answers a subscription.
    ///
    /// Finish the stream to show `_sah/graphql/complete`. Finish it with
    /// ``SAHGraphQLError/graphQL(_:)`` to show `_sah/graphql/error`, or with
    /// ``SAHGraphQLError/connectionClosed`` to show a lost connection. When the
    /// caller stops the iteration, the stream terminates, and its
    /// `onTermination` handler is the place of `_sah/graphql/unsubscribe`.
    ///
    /// - Parameter request: The subscription operation.
    /// - Returns: The stream of the GraphQL results.
    func subscribe(_ request: SAHGraphQLClient.Request) -> AsyncThrowingStream<JSONValue, any Error>

    /// Lists the endpoints.
    ///
    /// - Returns: The endpoints.
    /// - Throws: An error, for example ``SAHGraphQLError/connectionClosed``
    ///   to show a lost connection.
    func endpoints() async throws -> [SAHGraphQLClient.Endpoint]
}
