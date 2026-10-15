import FoundationModelsACP
import Observation
import Testing

@testable import FoundationModelsACPClient

// The tests of a request that the agent sends while it opens a session, or at
// once after it opened it (defect ^hfby9sz, from AgentViewKit ^4tw540d). The
// agent can ask an open question at once after a resume, and the AgentViewKit
// demo agent does. The request must be pending on the session model, and the
// client must not answer it with cancel.
//
// Each test fixes the order: the stub agent sends the request at one point of
// its handler, and the test waits for an event (the request is pending, or the
// agent got an answer) before it reads the state.

/// The point of a session request at which the stub agent asks its question.
private enum QuestionTiming: Sendable {
    /// The `session/resume` handler asks, and waits for the answer before it
    /// answers the resume.
    case beforeTheResumeAnswer

    /// The agent asks at once after the connection wrote the resume answer.
    case afterTheResumeAnswer
}

/// The answers that the stub agent got to its questions, in arrival order. It
/// is observable, so a test waits for an answer with no poll.
@MainActor @Observable
private final class AgentAnswers {
    /// The outcome of each permission request of the agent.
    var outcomes: [RequestPermissionOutcome] = []
}

/// A stub agent that asks one permission question for the test session while
/// it resumes that session.
private final class OpenQuestionStubAgent: Agent {
    /// The connection back to the client.
    private let connection: AgentSideConnection

    /// The point at which the agent asks.
    private let timing: QuestionTiming

    /// The record of the answers.
    private let answers: AgentAnswers

    /// Makes the stub.
    ///
    /// - Parameters:
    ///   - connection: The connection back to the client.
    ///   - timing: The point at which the agent asks.
    ///   - answers: The record of the answers.
    init(connection: AgentSideConnection, timing: QuestionTiming, answers: AgentAnswers) {
        self.connection = connection
        self.timing = timing
        self.answers = answers
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "open-question-stub-agent", version: "1.0.0"),
            protocolVersion: params.protocolVersion,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        switch timing {
        case .beforeTheResumeAnswer:
            try await ask()
        case .afterTheResumeAnswer:
            connection.afterRespondingToCurrentRequest { [self] in
                try? await ask()
            }
        }
        return ResumeSessionResponse()
    }

    /// Sends one permission request for the test session, and records the
    /// outcome that the client answered.
    ///
    /// - Throws: Whatever the connection threw.
    private func ask() async throws {
        let response = try await connection.requestPermission(SessionModelFixtures.permissionRequest())
        let answers = self.answers
        await MainActor.run { answers.outcomes.append(response.outcome) }
    }

    // The stub does not model the other methods. Each one refuses with
    // `methodNotFound`, as an agent that does not implement it does.

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.newSession)
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.prompt)
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.listSessions)
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
}

/// A connection model over the real ACP wire to an ``OpenQuestionStubAgent``.
@MainActor
private struct OpenQuestionConnection {
    /// The model under test.
    let model: ConnectionModel

    /// The record of the answers that the agent got.
    let answers: AgentAnswers

    /// The agent-side connection. The test holds it for the life of the test.
    let agentConnection: AgentSideConnection

    /// Connects a model to a stub agent, and initializes the connection.
    ///
    /// - Parameter timing: The point at which the agent asks.
    /// - Throws: The error of `initialize`.
    init(timing: QuestionTiming) async throws {
        let answers = AgentAnswers()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            OpenQuestionStubAgent(connection: connection, timing: timing, answers: answers)
        }
        model = ConnectionModel(coalescingCadence: .zero)
        _ = await model.connect(over: clientEnd)
        _ = try await model.initialize(makeInitializeRequest())
        self.answers = answers
    }

    /// The resume request of the test session.
    static let resumeRequest = ResumeSessionRequest(cwd: AbsolutePath(rawValue: "/"), sessionId: testSession)

    /// Waits until the question of the agent is pending on the model of the
    /// test session, or until the agent got an answer.
    func waitForTheQuestion() async {
        await waitFor {
            model.session(for: testSession)?.pendingPermissions.isEmpty == false || !answers.outcomes.isEmpty
        }
    }
}

/// The open-question tests, in one suite so that `swift test --filter
/// SessionOpenQuestionTests` selects them.
@MainActor
@Suite
struct SessionOpenQuestionTests {
    /// The agent asks during the resume, and answers the resume only after
    /// the user answered. The question must be pending on the model of the
    /// session while the resume runs, and the answer of the user must reach
    /// the agent.
    @Test func aQuestionBeforeTheResumeAnswerIsPendingOnTheSessionModel() async throws {
        let connected = try await OpenQuestionConnection(timing: .beforeTheResumeAnswer)
        let resume = Task { try await connected.model.resumeSession(OpenQuestionConnection.resumeRequest) }

        await connected.waitForTheQuestion()
        #expect(connected.answers.outcomes.isEmpty, "The client answered the question before the user did.")
        let session = try #require(connected.model.session(for: testSession))
        let pending = try #require(session.pendingPermissions.first)
        await session.selectPermission(pending.id, option: SessionModelFixtures.allowOption.optionId)

        let resumed = try await resume.value
        #expect(resumed === session)
        #expect(connected.answers.outcomes == [.selected(SelectedPermissionOutcome(optionId: SessionModelFixtures.allowOption.optionId))])
        withExtendedLifetime(connected.agentConnection) {}
    }

    /// The agent asks at once after it wrote the resume answer, as the
    /// AgentViewKit demo agent does. The question must be pending on the
    /// model of the session.
    @Test func aQuestionAtOnceAfterTheResumeAnswerIsPendingOnTheSessionModel() async throws {
        let connected = try await OpenQuestionConnection(timing: .afterTheResumeAnswer)

        let session = try await connected.model.resumeSession(OpenQuestionConnection.resumeRequest)
        await connected.waitForTheQuestion()

        #expect(connected.answers.outcomes.isEmpty, "The client answered the question before the user did.")
        let pending = try #require(session.pendingPermissions.first)
        await session.selectPermission(pending.id, option: SessionModelFixtures.allowOption.optionId)
        await waitFor { !connected.answers.outcomes.isEmpty }
        #expect(connected.answers.outcomes == [.selected(SelectedPermissionOutcome(optionId: SessionModelFixtures.allowOption.optionId))])
        withExtendedLifetime(connected.agentConnection) {}
    }
}
