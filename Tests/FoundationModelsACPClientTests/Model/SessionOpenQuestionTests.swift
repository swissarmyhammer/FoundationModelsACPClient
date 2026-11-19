import Foundation
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

    /// Why the raw agent stopped before the test ended, or `nil` while it
    /// runs. A wait of the test also ends on this record, so a broken agent
    /// fails the test and does not hang it.
    var agentEnd: String?
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
    /// test session, or until the agent got an answer. The close of the
    /// connection is the failure event.
    ///
    /// - Throws: ``WaitEndedOnFailure`` when the connection closed first.
    func waitForTheQuestion() async throws {
        try await waitUntil {
            model.session(for: testSession)?.pendingPermissions.isEmpty == false || !answers.outcomes.isEmpty
        } orFailWhen: {
            model.hasClosedConnection
        }
    }
}

extension ConnectionModel {
    /// Whether the connection of the model is closed: the agent closed its
    /// side, the read failed, or the host closed it. A wait of these tests
    /// ends on it as its failure event.
    fileprivate var hasClosedConnection: Bool {
        switch state {
        case .disconnected, .failed: true
        case .connecting, .connected: false
        }
    }
}

/// The answer that opens the test session. The raw agent sends its question
/// for the test session directly after this answer.
private enum OpeningAnswer: Sendable {
    /// The `session/new` answer opens the test session.
    case newSession

    /// The `session/new` answer opens the source session
    /// ``otherTestSession``, with no question. The `session/fork` answer of
    /// that source opens the test session.
    case forkSession
}

/// An agent that writes raw NDJSON frames on the agent end of an in-memory
/// pair. It answers `initialize`, and it advertises `session/fork`. It
/// answers the request that opens the test session AND sends a permission
/// request for that session in the SAME transport write. Thus the reader of
/// the client decodes the response and then the request in one read, with no
/// frame between them.
private final class RawOpenQuestionAgent: Sendable {
    /// The wire id of the permission request of the agent.
    static let questionId = "agent-question-1"

    /// The agent end of the pair.
    private let transport: InMemoryTransport

    /// The record of the answers.
    private let answers: AgentAnswers

    /// The answer that opens the test session.
    private let opening: OpeningAnswer

    /// Makes the agent.
    ///
    /// - Parameters:
    ///   - transport: The agent end of the pair.
    ///   - answers: The record of the answers.
    ///   - opening: The answer that opens the test session.
    init(transport: InMemoryTransport, answers: AgentAnswers, opening: OpeningAnswer) {
        self.transport = transport
        self.answers = answers
        self.opening = opening
    }

    /// Reads the frames of the client until the stream ends, and answers
    /// them.
    ///
    /// On an error, the agent closes its end, so each request of the client
    /// fails with a closed connection and the test does not wait for ever.
    ///
    /// - Throws: The error that stopped the agent.
    func run() async throws {
        do {
            var buffer = Data()
            for try await chunk in transport.bytes {
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<end]
                    buffer.removeSubrange(buffer.startIndex...end)
                    try await answer(line)
                }
            }
        } catch {
            transport.close()
            let answers = self.answers
            let reason = "\(error)"
            await MainActor.run { answers.agentEnd = reason }
            throw error
        }
    }

    /// Answers one frame of the client.
    ///
    /// - Parameter line: The JSON text of the frame.
    private func answer(_ line: Data) async throws {
        guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        switch frame["method"] as? String {
        case ClientRequestSpan.Method.initialize?:
            let request = try JSONDecoder().decode(InitializeRequest.self, from: Self.paramsData(of: frame))
            let response = InitializeResponse(
                info: Implementation(name: "raw-open-question-agent", version: "1.0.0"),
                protocolVersion: request.protocolVersion,
                capabilities: AgentCapabilities(session: SessionCapabilities(fork: SessionForkCapabilities()))
            )
            try await transport.write(Self.response(to: frame, result: response))
        case ClientRequestSpan.Method.newSession? where opening == .forkSession:
            try await transport.write(Self.response(to: frame, result: NewSessionResponse(sessionId: otherTestSession)))
        case ClientRequestSpan.Method.newSession?:
            try await answerAndAsk(frame, result: NewSessionResponse(sessionId: testSession))
        case ClientRequestSpan.Method.forkSession?:
            try await answerAndAsk(frame, result: ForkSessionResponse(sessionId: testSession))
        case ClientRequestSpan.Method.resumeSession?:
            // The fork call replays the history of the fork with a resume.
            // The agent has no history to replay.
            try await transport.write(Self.response(to: frame, result: ResumeSessionResponse()))
        case nil where frame["id"] as? String == Self.questionId:
            let result = try JSONSerialization.data(withJSONObject: frame["result"] ?? [:])
            let outcome = try JSONDecoder().decode(RequestPermissionResponse.self, from: result).outcome
            let answers = self.answers
            await MainActor.run { answers.outcomes.append(outcome) }
        case let method? where frame["id"] != nil:
            // Each other request gets an error, so no call of the client
            // waits for ever.
            let error = ACPError(code: .methodNotFound, message: "The raw agent does not serve \(method).")
            try await transport.write(Self.frame(["jsonrpc": "2.0", "id": frame["id"]!, "error": try Self.json(error)]))
        default:
            break
        }
    }

    /// Answers the request that opens the test session, and asks the
    /// question for the test session in the same transport write.
    ///
    /// - Parameters:
    ///   - frame: The decoded request frame.
    ///   - result: The answer that opens the test session.
    /// - Throws: The error of the encoder or of the transport.
    private func answerAndAsk(_ frame: [String: Any], result: some Encodable) async throws {
        // One write holds the response and the request, in this order.
        let question = Self.frame([
            "jsonrpc": "2.0", "id": Self.questionId, "method": ClientRequestSpan.Method.requestPermission,
            "params": try Self.json(SessionModelFixtures.permissionRequest()),
        ])
        try await transport.write(Self.response(to: frame, result: result) + question)
    }

    /// Gives the NDJSON response frame to one request frame.
    ///
    /// - Parameters:
    ///   - frame: The decoded request frame.
    ///   - result: The result of the response.
    /// - Returns: The JSON text of the response and the newline.
    /// - Throws: The error of the encoder.
    private static func response(to frame: [String: Any], result: some Encodable) throws -> Data {
        Self.frame(["jsonrpc": "2.0", "id": frame["id"]!, "result": try json(result)])
    }

    /// Gives the JSON text of the `params` member of a frame.
    ///
    /// - Parameter frame: The decoded frame.
    /// - Returns: The JSON text of the params.
    /// - Throws: The error of the encoder.
    private static func paramsData(of frame: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: frame["params"] ?? [:])
    }

    /// Gives a wire value as a JSON object.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The JSON object.
    /// - Throws: The error of the encoder.
    private static func json(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    /// Gives one NDJSON frame.
    ///
    /// - Parameter object: The JSON object of the frame.
    /// - Returns: The JSON text and the newline.
    private static func frame(_ object: [String: Any]) -> Data {
        // The objects here hold only JSON values, so the encode cannot fail.
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object) + Data("\n".utf8)
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
        defer { await connected.model.disconnect() }
        let resume = Task { try await connected.model.resumeSession(OpenQuestionConnection.resumeRequest) }

        try await connected.waitForTheQuestion()
        #expect(connected.answers.outcomes.isEmpty, "The client answered the question before the user did.")
        let session = try #require(connected.model.session(for: testSession))
        let pending = try #require(session.pendingPermissions.first)
        await session.selectPermission(pending.id, option: SessionModelFixtures.allowOption.optionId)

        // The agent answers the resume only after it got the answer. Thus the
        // test waits for the answer first, and the close of the connection
        // ends that wait when the answer does not come.
        try await waitUntil { !connected.answers.outcomes.isEmpty } orFailWhen: {
            connected.model.hasClosedConnection
        }
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
        defer { await connected.model.disconnect() }

        let session = try await connected.model.resumeSession(OpenQuestionConnection.resumeRequest)
        try await connected.waitForTheQuestion()

        #expect(connected.answers.outcomes.isEmpty, "The client answered the question before the user did.")
        let pending = try #require(session.pendingPermissions.first)
        await session.selectPermission(pending.id, option: SessionModelFixtures.allowOption.optionId)
        try await waitUntil { !connected.answers.outcomes.isEmpty } orFailWhen: { session.isClosed }
        #expect(connected.answers.outcomes == [.selected(SelectedPermissionOutcome(optionId: SessionModelFixtures.allowOption.optionId))])
        withExtendedLifetime(connected.agentConnection) {}
    }

    /// The agent sends the `session/new` answer and a question for the new
    /// session in one transport write, and the question must be pending on
    /// the model of the new session. This is an end-to-end check of the real
    /// wire.
    ///
    /// This test does NOT prove the order. The scheduler decides whether the
    /// register of the model or the router comes first, and with no fix the
    /// register usually comes first, so the test passes also on the code
    /// with no hold. ``aQuestionThatReachesTheRouterBeforeTheNewSessionRegisterWaitsForIt()``
    /// fixes the order.
    @Test func aQuestionInTheSameWriteAsTheNewSessionAnswerIsPendingOnTheSessionModel() async throws {
        let connected = try await RawOpenQuestionConnection(opening: .newSession, holdsTheRegister: false)
        defer { connected.agentRun.cancel() }
        defer { await connected.model.disconnect() }

        let session = try await connected.model.newSession(RawOpenQuestionConnection.newSessionRequest)

        try await connected.expectTheQuestionIsPending(on: session)
    }

    /// The agent sends the `session/new` answer and a question for the new
    /// session in one transport write. The test holds the register of the new
    /// model until the question reached the router, so the order is fixed: the
    /// router looks up the session before the model is registered. The router
    /// must wait for the open, and the question must then be pending on the
    /// model of the new session.
    ///
    /// The seam opens when the router waits for the opening session, or when
    /// the agent got an answer. With no hold in the router, the router
    /// answers cancel at once, and the test fails.
    @Test func aQuestionThatReachesTheRouterBeforeTheNewSessionRegisterWaitsForIt() async throws {
        let connected = try await RawOpenQuestionConnection(opening: .newSession, holdsTheRegister: true)
        defer { connected.agentRun.cancel() }
        defer { await connected.model.disconnect() }

        let session = try await connected.model.newSession(RawOpenQuestionConnection.newSessionRequest)

        try await connected.expectTheQuestionIsPending(on: session)
    }

    /// The agent sends the `session/fork` answer and a question for the fork
    /// in one transport write. The test holds the register of the model of
    /// the fork until the question reached the router. The router must wait
    /// for the open of the fork, and the question must then be pending on
    /// the model of the fork.
    ///
    /// This test does NOT prove the order. It has the same limit as
    /// ``aQuestionInTheSameWriteAsTheNewSessionAnswerIsPendingOnTheSessionModel()``.
    /// The fork call and the router both run on the main actor, and the fork
    /// call usually gets there first. Thus the test passes also on the code
    /// with no hook, which marks the fork as opening only when the main
    /// actor reads the answer. The `onResponse` hook of
    /// `ClientSideConnection.forkSession(_:onResponse:)` gives the order: it
    /// marks the fork as opening on the reader, before the question goes to
    /// the router.
    @Test func aQuestionDirectlyAfterTheForkAnswerIsPendingOnTheForkModel() async throws {
        let connected = try await RawOpenQuestionConnection(opening: .forkSession, holdsTheRegister: true)
        defer { connected.agentRun.cancel() }
        defer { await connected.model.disconnect() }
        _ = try await connected.model.newSession(RawOpenQuestionConnection.newSessionRequest)

        let fork = try await connected.model.forkSession(otherTestSession)

        try await connected.expectTheQuestionIsPending(on: fork)
    }
}

/// A connection model over the real ACP wire to a ``RawOpenQuestionAgent``.
@MainActor
private struct RawOpenQuestionConnection {
    /// The model under test.
    let model: ConnectionModel

    /// The record of the answers that the agent got.
    let answers: AgentAnswers

    /// The task that runs the agent. The test cancels it at its end.
    let agentRun: Task<Void, any Error>

    /// The new-session request of the tests.
    static let newSessionRequest = NewSessionRequest(cwd: AbsolutePath(rawValue: "/"))

    /// Connects a model to a raw agent, and initializes the connection. On a
    /// failure, the model disconnects and the agent stops.
    ///
    /// - Parameters:
    ///   - opening: The answer that opens the test session.
    ///   - holdsTheRegister: Whether the register of the model of the test
    ///     session waits until the question of the agent waits for the open
    ///     of that session. This fixes the order: the router looks up the
    ///     test session before its model is registered.
    /// - Throws: The error of `initialize`.
    init(opening: OpeningAnswer, holdsTheRegister: Bool) async throws {
        let answers = AgentAnswers()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = RawOpenQuestionAgent(transport: agentEnd, answers: answers, opening: opening)
        let agentRun = Task { try await agent.run() }
        let model = ConnectionModel(coalescingCadence: .zero)
        if holdsTheRegister {
            Self.holdTheRegisterOfTheTestSession(of: model, answers: answers)
        }
        _ = await model.connect(over: clientEnd)
        do {
            _ = try await model.initialize(makeInitializeRequest())
        } catch {
            await model.disconnect()
            agentRun.cancel()
            throw error
        }
        self.model = model
        self.answers = answers
        self.agentRun = agentRun
    }

    /// Holds the register of the model of the test session until the
    /// question of the agent waits for the open of that session, or until
    /// the agent got an answer. The register of each other session does not
    /// wait.
    ///
    /// - Parameters:
    ///   - model: The model under test.
    ///   - answers: The record of the answers that the agent got.
    private static func holdTheRegisterOfTheTestSession(of model: ConnectionModel, answers: AgentAnswers) {
        let routeState = RouteState()
        let opening = model.openingSessions
        model.beforeRegisteringNewSession = { [weak model] sessionId in
            guard sessionId == testSession else { return }
            Task {
                await opening.waitForAWaiter(on: sessionId)
                await MainActor.run { routeState.questionWaits = true }
            }
            // The seam cannot throw. A wait that ends on its failure event
            // records an issue itself, so the test fails also here.
            try? await waitUntil {
                routeState.questionWaits || !answers.outcomes.isEmpty || answers.agentEnd != nil
            } orFailWhen: {
                model?.hasClosedConnection ?? true
            }
        }
    }

    /// Expects that the question of the agent is pending on a session model,
    /// that the client did not answer it, and that the choice of the user
    /// goes to the agent.
    ///
    /// - Parameters:
    ///   - session: The model of the test session.
    ///   - sourceLocation: The location of the caller, for each failure.
    /// - Throws: ``WaitEndedOnFailure`` when the session closed during a
    ///   wait, or the error of `#require` when no question is pending.
    func expectTheQuestionIsPending(
        on session: SessionModel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let answers = self.answers
        try await waitUntil(
            { !session.pendingPermissions.isEmpty || !answers.outcomes.isEmpty || answers.agentEnd != nil },
            orFailWhen: { session.isClosed },
            sourceLocation: sourceLocation
        )
        #expect(answers.agentEnd == nil, "The agent ended: \(answers.agentEnd ?? "")", sourceLocation: sourceLocation)
        #expect(answers.outcomes.isEmpty, "The client answered the question before the user did.", sourceLocation: sourceLocation)
        let pending = try #require(session.pendingPermissions.first, sourceLocation: sourceLocation)
        await session.selectPermission(pending.id, option: SessionModelFixtures.allowOption.optionId)
        try await waitUntil(
            { !answers.outcomes.isEmpty || answers.agentEnd != nil },
            orFailWhen: { session.isClosed },
            sourceLocation: sourceLocation
        )
        #expect(
            answers.outcomes == [.selected(SelectedPermissionOutcome(optionId: SessionModelFixtures.allowOption.optionId))],
            sourceLocation: sourceLocation
        )
    }
}
/// Records that a routed question waits for its opening session. It is
/// observable, so the seam of the test waits for it with no poll.
@MainActor @Observable
private final class RouteState {
    /// Whether the router waits for the open of the session of the question.
    var questionWaits = false
}
