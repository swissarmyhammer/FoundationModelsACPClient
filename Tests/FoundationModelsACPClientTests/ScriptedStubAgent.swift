import Foundation
import FoundationModelsACP

@testable import FoundationModelsACPClient

/// A stub agent that sends a fixed update script during one prompt turn.
///
/// The connection read loop applies each notification in wire order before
/// it delivers the prompt acknowledgement, so a test can assert on the final
/// observable state after the prompt call returns.
final class ScriptedStubAgent: Agent {
    /// The connection back to the client.
    private let connection: AgentSideConnection

    /// The session that the script belongs to.
    private let session: SessionId

    /// The updates to send, in order, when a prompt arrives.
    private let script: [SessionUpdate]

    /// Creates the stub.
    ///
    /// - Parameters:
    ///   - connection: The connection back to the client.
    ///   - session: The session that the script belongs to.
    ///   - script: The updates to send during the prompt turn.
    init(connection: AgentSideConnection, session: SessionId, script: [SessionUpdate]) {
        self.connection = connection
        self.session = session
        self.script = script
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "stub-agent", version: "1.0.0"),
            protocolVersion: params.protocolVersion
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        throw RequestError.methodNotFound("session/new")
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
        for update in script {
            try await connection.sessionUpdate(
                UpdateSessionNotification(sessionId: session, update: update)
            )
        }
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}
