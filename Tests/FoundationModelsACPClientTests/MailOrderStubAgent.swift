import FoundationModelsACP
import Synchronization

@testable import FoundationModelsACPClient

/// A stub agent with the wire order of FoundationModelsACPAgent 293be4b,
/// where a prompt is mail.
///
/// - `session/prompt` answers at once, with the next message id of the list
///   that the test gives. The stub sends no update for the prompt. A second
///   prompt while the first one is open also gets its answer at once.
/// - The test sends each update itself with ``send(_:)``, after the answer:
///   the echo of the user message, `running`, the chunks, a compaction, and
///   `idle`. Thus the test fixes the order of each step.
/// - `session/cancel` sends nothing. The stub gives each cancel on
///   ``cancels``, and the test sends the `idle` with the `cancelled` stop
///   reason later, as the real agent does when the model work ends.
/// - ``startElicitation(_:)`` sends `elicitation/create` with no prompt open.
///   A cancel of the returned task makes the connection send
///   `$/cancel_request`, as the real agent does when Router ends the
///   question.
///
/// ``ScriptedStubAgent`` sends its script before the prompt answer: the old
/// order of a prompt turn.
final class MailOrderStubAgent: Agent {
    /// The connection back to the client.
    private let connection: AgentSideConnection

    /// The message ids that the next `session/prompt` answers give, in order.
    ///
    /// The connection serves each request on a task of its own, so the list
    /// must tolerate a change from a thread other than the test body's.
    private let remainingMessageIds: Mutex<[MessageId]>

    /// The input side of ``cancels``.
    private let cancelInput: AsyncStream<CancelSessionNotification>.Continuation

    /// Each `session/cancel` that the stub got, in arrival order. A test reads
    /// it to know that the cancel reached the agent before it sends the
    /// `idle` of the cancel.
    let cancels: AsyncStream<CancelSessionNotification>

    /// Makes the stub.
    ///
    /// - Parameters:
    ///   - connection: The connection back to the client.
    ///   - messageIds: The message id of each `session/prompt` answer, in
    ///     order. A prompt after the last id is refused with
    ///     `internalError`.
    init(connection: AgentSideConnection, messageIds: [MessageId]) {
        self.connection = connection
        remainingMessageIds = Mutex(messageIds)
        (cancels, cancelInput) = AsyncStream.makeStream()
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "mail-order-stub-agent", version: "1.0.0"),
            protocolVersion: params.protocolVersion,
            capabilities: AgentCapabilities()
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: testSession)
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        let messageId = remainingMessageIds.withLock { ids in
            ids.isEmpty ? nil : ids.removeFirst()
        }
        guard let messageId else {
            throw RequestError.internalError(detail: "the stub has no message id for this prompt")
        }
        return PromptResponse(messageId: messageId)
    }

    func sessionCancel(_ params: CancelSessionNotification) async {
        cancelInput.yield(params)
    }

    // The stub does not model the other methods. Each one refuses with
    // `methodNotFound`, as an agent that does not implement it does.

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.listSessions)
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.resumeSession)
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.closeSession)
    }

    func loginAuth(_ params: LoginAuthRequest) async throws -> LoginAuthResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.login)
    }

    func logoutAuth(_ params: LogoutAuthRequest) async throws -> LogoutAuthResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.logout)
    }

    func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.deleteSession)
    }

    func setSessionConfigOption(_ params: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.setConfigOption)
    }

    /// Sends one update for the test session.
    ///
    /// - Parameter update: The update to send.
    /// - Throws: Whatever the connection threw.
    func send(_ update: SessionUpdate) async throws {
        try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
    }

    /// Sends each update in order.
    ///
    /// - Parameter updates: The updates to send.
    /// - Throws: Whatever the connection threw.
    func send(_ updates: [SessionUpdate]) async throws {
        for update in updates {
            try await send(update)
        }
    }

    /// Sends `elicitation/create`, and gives the task of the call.
    ///
    /// - Parameter request: The elicitation to send.
    /// - Returns: The task of the call. Its cancel makes the connection send
    ///   `$/cancel_request` for the request.
    func startElicitation(_ request: CreateElicitationRequest) -> Task<CreateElicitationResponse, any Error> {
        Task { [connection] in try await connection.createElicitation(request) }
    }

    /// Sends `elicitation/create` with a cancel box, and gives the task of
    /// the call.
    ///
    /// - Parameters:
    ///   - request: The elicitation to send.
    ///   - cancellation: The box of the `_meta` that the `$/cancel_request`
    ///     carries. Set the `_meta` before the cancel of the task.
    /// - Returns: The task of the call. Its cancel makes the connection send
    ///   `$/cancel_request` for the request, with the `_meta` of the box.
    func startElicitation(
        _ request: CreateElicitationRequest,
        cancellation: OutboundCancellation
    ) -> Task<CreateElicitationResponse, any Error> {
        Task { [connection] in try await connection.createElicitation(request, cancellation: cancellation) }
    }

    /// Sends `session/request_permission`, and gives the task of the call.
    ///
    /// - Parameter request: The permission request to send.
    /// - Returns: The task of the call. Its cancel makes the connection send
    ///   `$/cancel_request` for the request, with no `_meta`.
    func startPermission(_ request: RequestPermissionRequest) -> Task<RequestPermissionResponse, any Error> {
        Task { [connection] in try await connection.requestPermission(request) }
    }

    /// Sends `session/request_permission` with a cancel box, and gives the
    /// task of the call.
    ///
    /// - Parameters:
    ///   - request: The permission request to send.
    ///   - cancellation: The box of the `_meta` that the `$/cancel_request`
    ///     carries. Set the `_meta` before the cancel of the task.
    /// - Returns: The task of the call. Its cancel makes the connection send
    ///   `$/cancel_request` for the request, with the `_meta` of the box.
    func startPermission(
        _ request: RequestPermissionRequest,
        cancellation: OutboundCancellation
    ) -> Task<RequestPermissionResponse, any Error> {
        Task { [connection] in try await connection.requestPermission(request, cancellation: cancellation) }
    }
}
