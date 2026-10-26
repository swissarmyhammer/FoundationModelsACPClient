import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import GraphQL

/// Why ``SAHGraphQLClient/endpoint(named:sessionId:)`` cannot give an
/// endpoint.
public enum SAHGraphQLEndpointError: Error, Hashable, Sendable {
    /// The server has no endpoint with this name.
    case unknownEndpoint(name: String)

    /// The endpoint has the session folder as its scope, and the call gave no
    /// session.
    case missingSession(endpoint: String)
}

/// One named endpoint of the server, as a `GraphQLEndpoint` of
/// FoundationModelsExtras.
///
/// Each call goes through the `_sah/graphql/*` tunnel of a
/// ``SAHGraphQLClient``. A host gives this value to a view model that knows
/// only `GraphQLEndpoint`. The same view model can take an endpoint of the
/// process, for example `KanbanGraph`, in its tests.
///
/// Get a value from ``SAHGraphQLClient/endpoint(named:sessionId:)``. The
/// value runs no GraphQL engine. It uses only the `Map` value type of the
/// GraphQL package, which the protocol names.
///
/// - The name, the version, the scope and the schema come from
///   `_sah/graphql/endpoints`.
/// - An endpoint with the session folder as its scope sends one session id
///   with each call. An endpoint with the server as its scope sends no
///   session id.
/// - The client does not send the `viewer` of a call. The agent fills the
///   viewer from the connection of the call.
/// - Each result is JSON text with sorted keys and no escaped slashes.
public struct SAHGraphQLEndpoint: GraphQLEndpoint {
    /// The name of the endpoint, for example `kanban`.
    public let name: String

    /// The version of the schema of the endpoint.
    public let version: String

    /// The scope of the endpoint.
    public let scope: GraphQLEndpointScope

    /// The schema of the endpoint, in SDL.
    public let schema: String

    /// The session that each call sends, or `nil` for an endpoint with the
    /// server as its scope.
    public let sessionId: SessionId?

    /// The client that sends each call.
    private let client: SAHGraphQLClient

    /// Makes an endpoint over a client.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint of the server.
    ///   - sessionId: The session of each call. The value ignores it for an
    ///     endpoint with the server as its scope.
    ///   - client: The client that sends each call.
    /// - Throws: ``SAHGraphQLEndpointError/missingSession(endpoint:)`` for an
    ///   endpoint with the session folder as its scope and no session.
    init(_ endpoint: SAHGraphQLClient.Endpoint, sessionId: SessionId?, client: SAHGraphQLClient) throws {
        name = endpoint.name
        version = endpoint.version
        schema = endpoint.schema
        self.client = client
        switch endpoint.scope {
        case .sessionFolder:
            guard let sessionId else {
                throw SAHGraphQLEndpointError.missingSession(endpoint: endpoint.name)
            }
            scope = .sessionFolder
            self.sessionId = sessionId
        case .server:
            scope = .server
            self.sessionId = nil
        }
    }

    /// Runs one GraphQL document through `_sah/graphql/execute`.
    ///
    /// - Parameters:
    ///   - query: The GraphQL document.
    ///   - variables: The values of the variables of the document.
    ///   - operationName: The operation of the document to run, or `nil`.
    ///   - viewer: Not used. The agent fills the viewer from the connection.
    /// - Returns: The GraphQL response as JSON text. A GraphQL error does not
    ///   throw: the response holds it in `errors`.
    /// - Throws: The errors of ``SAHGraphQLClient/execute(endpoint:sessionId:document:variables:operationName:)``,
    ///   or an error of the JSON coders.
    public func execute(
        query: String,
        variables: [String: Map],
        operationName: String?,
        viewer: GraphQLViewer?
    ) async throws -> String {
        let result = try await client.execute(
            endpoint: name,
            sessionId: sessionId,
            document: query,
            variables: try Self.jsonVariables(variables),
            operationName: operationName
        )
        return try Self.text(of: result)
    }

    /// Starts one GraphQL subscription through `_sah/graphql/subscribe`.
    ///
    /// The stream follows the rule of `GraphQLEndpoint`: a
    /// `_sah/graphql/error` gives one last response with the `errors` of the
    /// server, and the stream then ends normally. A closed connection and a
    /// refused subscribe request throw, as in
    /// ``SAHGraphQLClient/subscribe(endpoint:sessionId:document:variables:operationName:)``.
    /// When the caller stops the iteration, the client sends
    /// `_sah/graphql/unsubscribe`.
    ///
    /// - Parameters:
    ///   - query: The subscription document.
    ///   - variables: The values of the variables of the document.
    ///   - operationName: The operation of the document to run, or `nil`.
    ///   - viewer: Not used. The agent fills the viewer from the connection.
    /// - Returns: The GraphQL response of each event as JSON text.
    /// - Throws: An error of the JSON coders for the variables.
    public func subscribe(
        query: String,
        variables: [String: Map],
        operationName: String?,
        viewer: GraphQLViewer?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let results = client.subscribe(
            endpoint: name,
            sessionId: sessionId,
            document: query,
            variables: try Self.jsonVariables(variables),
            operationName: operationName
        )
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let forward = Task {
            do {
                for try await result in results {
                    continuation.yield(try Self.text(of: result))
                }
                continuation.finish()
            } catch SAHGraphQLError.graphQL(let errors) {
                continuation.yield(Self.errorsText(errors))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            forward.cancel()
        }
        return stream
    }

    /// Gives the variables of a call as the JSON values of the tunnel.
    ///
    /// - Parameter variables: The `Map` values of the variables.
    /// - Returns: The JSON values.
    /// - Throws: An error of the JSON coders.
    private static func jsonVariables(_ variables: [String: Map]) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(variables))
    }

    /// Gives a GraphQL result as JSON text with sorted keys and no escaped
    /// slashes, the form of the endpoints of FoundationModelsExtras.
    ///
    /// - Parameter result: The result.
    /// - Returns: The JSON text.
    /// - Throws: An error of the JSON encoder.
    private static func text(of result: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(result), as: UTF8.self)
    }

    /// Gives the response of a subscription that the server ended with
    /// errors.
    ///
    /// - Parameter errors: The `errors` array of `_sah/graphql/error`.
    /// - Returns: The `{"errors": ...}` JSON text.
    private static func errorsText(_ errors: JSONValue) -> String {
        // A JSONValue always encodes, so the fallback is not reachable.
        (try? text(of: .object(["errors": errors]))) ?? #"{"errors":[]}"#
    }
}

extension SAHGraphQLClient {
    /// Gives one named endpoint of the server as a `GraphQLEndpoint` of
    /// FoundationModelsExtras.
    ///
    /// The call reads `_sah/graphql/endpoints` one time, for the version, the
    /// scope and the schema of the endpoint. Each call of the endpoint then
    /// goes through this client.
    ///
    /// - Parameters:
    ///   - name: The name of the endpoint, for example `kanban`.
    ///   - sessionId: The session that selects the data of an endpoint with
    ///     the session folder as its scope. An endpoint with the server as
    ///     its scope ignores it.
    /// - Returns: The endpoint.
    /// - Throws: ``SAHGraphQLEndpointError/unknownEndpoint(name:)`` when the
    ///   server has no endpoint with this name,
    ///   ``SAHGraphQLEndpointError/missingSession(endpoint:)`` for an endpoint
    ///   with the session folder as its scope and no session, or an error of
    ///   ``endpoints()``.
    public func endpoint(named name: String, sessionId: SessionId? = nil) async throws -> SAHGraphQLEndpoint {
        guard let endpoint = try await endpoints().first(where: { $0.name == name }) else {
            throw SAHGraphQLEndpointError.unknownEndpoint(name: name)
        }
        return try SAHGraphQLEndpoint(endpoint, sessionId: sessionId, client: self)
    }
}
