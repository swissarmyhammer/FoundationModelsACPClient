import Foundation
import FoundationModelsACP

@testable import FoundationModelsACPClient

/// A stub agent that sends a fixed update script during one prompt turn.
///
/// The connection read loop applies each notification in wire order before
/// it delivers the prompt acknowledgement, so a test can assert on the final
/// observable state after the prompt call returns.
///
/// The stub answers `session/new` with the session the script belongs to,
/// because a test that drives the whole turn path opens a session before it
/// prompts. Every other session method stays unanswered: no test needs one,
/// and a stub that answers a method it does not model would hide a mistake.
///
/// A stub built with an elicitation asks the client for that elicitation
/// before it sends the script. The prompt turn then ends only after the
/// client answered, which is how a test proves that a headless client
/// refuses at once rather than waiting for a person.
final class ScriptedStubAgent: Agent {
    /// The connection back to the client.
    private let connection: AgentSideConnection

    /// The session that the script belongs to.
    private let session: SessionId

    /// The updates to send, in order, when a prompt arrives.
    private let script: [SessionUpdate]

    /// The elicitation to ask for when a prompt arrives, or `nil` to ask
    /// for none.
    private let elicitation: CreateElicitationRequest?

    /// Creates the stub.
    ///
    /// - Parameters:
    ///   - connection: The connection back to the client.
    ///   - session: The session that the script belongs to.
    ///   - script: The updates to send during the prompt turn.
    ///   - elicitation: The elicitation to ask for at the start of the
    ///     prompt turn, or `nil` to ask for none.
    init(
        connection: AgentSideConnection,
        session: SessionId,
        script: [SessionUpdate],
        elicitation: CreateElicitationRequest? = nil
    ) {
        self.connection = connection
        self.session = session
        self.script = script
        self.elicitation = elicitation
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "stub-agent", version: "1.0.0"),
            protocolVersion: params.protocolVersion
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: session)
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        throw RequestError.methodNotFound("session/list")
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        throw RequestError.methodNotFound("session/resume")
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        throw RequestError.methodNotFound("session/close")
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        if let elicitation {
            _ = try await connection.createElicitation(elicitation)
        }
        for update in script {
            try await connection.sessionUpdate(
                UpdateSessionNotification(sessionId: session, update: update)
            )
        }
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}
