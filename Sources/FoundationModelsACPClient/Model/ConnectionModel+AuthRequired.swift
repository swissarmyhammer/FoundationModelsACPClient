import FoundationModelsACP

// The `-32000` part of `ConnectionModel`: the agent answers a request with
// `authentication_required` when it needs a login before that request. The
// model then records the fact in `authState`, so a host does not have to find
// it in the error of the call.
//
// The session and list requests of the model go out through
// `sendRecordingAuth(_:through:)`. `initialize`, `auth/login`, and
// `auth/logout` do not: `initialize` sets the auth state from its answer, and
// `login(_:)` and `logout(_:)` record each failure of their own.

extension ConnectionModel {
    /// Sets ``authState`` to ``AuthState/required(_:)`` with the auth
    /// methods of the agent when an error is the `-32000` answer of the
    /// agent.
    ///
    /// The answer can come after a successful login too, for example when
    /// the login expired. Each other error changes nothing.
    ///
    /// - Parameter error: The error that a request threw.
    func recordAuthRequired(ifThrownBy error: any Error) {
        guard let requestError = error as? RequestError, requestError.code == .authenticationRequired else {
            return
        }
        authState = .required(authMethods)
    }

    /// Sends one request in a client request span, and records a `-32000`
    /// answer in ``authState``.
    ///
    /// The span, the request metrics, and the W3C trace context in the
    /// `_meta` of the request are those of
    /// `ClientRequestSpan.send(_:parent:through:)`.
    ///
    /// - Parameters:
    ///   - message: The request as the caller made it.
    ///   - send: Sends the request. It gets the request with the traced
    ///     `_meta`.
    /// - Returns: The value of `send`.
    /// - Throws: The error of `send`, after ``recordAuthRequired(ifThrownBy:)``
    ///   read it.
    func sendRecordingAuth<Message: TracedClientMessage, Output>(
        _ message: Message,
        through send: nonisolated(nonsending) (Message) async throws -> Output
    ) async throws -> Output {
        do {
            return try await ClientRequestSpan.send(message, through: send)
        } catch {
            recordAuthRequired(ifThrownBy: error)
            throw error
        }
    }
}
