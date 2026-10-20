import FoundationModelsACP

/// Why a call of ``SAHGraphQLClient`` failed, or why a subscription ended
/// before `_sah/graphql/complete`.
///
/// A client model reads the case to decide how to resume. For example, a
/// board model subscribes again from its change cursor, and reads the board
/// again when the server cannot resume from that cursor.
public enum SAHGraphQLError: Error, Hashable, Sendable {
    /// The server ended the subscription with `_sah/graphql/error`.
    ///
    /// The value is the `errors` array of GraphQL errors that the server
    /// sent. Each error can have a code in `extensions.code`.
    case graphQL(JSONValue)

    /// The connection closed before the result, or while the subscription
    /// was open.
    case connectionClosed
}
