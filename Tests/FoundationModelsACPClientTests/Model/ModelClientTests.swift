import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of `ModelClient`, the router that a `ConnectionModel` serves: each
// route of a permission request, an elicitation and an `elicitation/complete`
// to the open session models, and each fallback.
//
// `InMemoryTransport.pair()` gives the real ACP wire, with a
// `ScriptedStubAgent` on the agent end. The test sends each request through
// the agent-side connection, so the answer crosses the wire back to the agent.
// The model logs to a test logger, so a test can count the warnings of the
// router.

/// A model that is connected over an in-memory pair to a scripted stub agent,
/// and that logs to a test logger.
@MainActor
private struct RoutedModel {
    /// The model under test.
    let model: ConnectionModel

    /// The agent-side connection. Each test sends its requests through it.
    let agentConnection: AgentSideConnection

    /// The messages that the model logged, in order.
    private let messages: ThreadSafeBuffer<String>

    /// The messages that the model logged, in order.
    var loggedMessages: [String] {
        messages.elements
    }

    /// Connects a new model to a new stub agent.
    init() async {
        let messages = ThreadSafeBuffer<String>()
        self.messages = messages
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            ScriptedStubAgent(connection: connection, session: testSession, script: [])
        }
        model = ConnectionModel(logger: ACPLogger { messages.append($0) })
        _ = await model.connect(over: clientEnd)
    }

    /// Makes the model of the test session and opens it.
    ///
    /// - Returns: The open session model.
    func openTestSession() -> SessionModel {
        let session = model.makeSessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        model.register(session)
        return session
    }

    /// Sends an elicitation from the agent, and waits until the session holds
    /// it as pending.
    ///
    /// - Parameters:
    ///   - request: The elicitation to send.
    ///   - session: The session model that must hold the elicitation.
    /// - Returns: The task of the agent's call.
    /// - Throws: `CancellationError` when the test time limit cancels the wait.
    func startElicitation(
        _ request: CreateElicitationRequest,
        on session: SessionModel
    ) async throws -> Task<CreateElicitationResponse, any Error> {
        try await ElicitationFixtures.start(request, over: agentConnection) { !session.pendingElicitations.isEmpty }
    }
}

/// The router tests, in one suite so that `swift test --filter
/// ModelClientTests` selects them. A wait for an answer that never comes would
/// suspend for ever, so the suite has a time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ModelClientTests {
    /// The id of a session that no model holds.
    private let unknownSession = SessionId(rawValue: "session-unknown")

    /// The form values that the user gives to an accepted form elicitation.
    private let formContent: JSONValue = .object(["name": .string("orion")])

    // MARK: - Permission requests

    @Test func aPermissionRequestForAnOpenSessionLandsInItsModelAndTheChoiceReachesTheAgent() async throws {
        let routed = await RoutedModel()
        let session = routed.openTestSession()
        let request = SessionModelFixtures.permissionRequest()

        let call = Task { [agentConnection = routed.agentConnection] in
            try await agentConnection.requestPermission(request)
        }
        try await waitUntil { !session.pendingPermissions.isEmpty }
        let pending = try #require(session.pendingPermissions.first)
        #expect(pending.request == request)
        session.selectPermission(pending.id, option: SessionModelFixtures.allowOption.optionId)

        let response = try await call.value
        #expect(response.outcome == .selected(SelectedPermissionOutcome(optionId: SessionModelFixtures.allowOption.optionId)))
        #expect(routed.loggedMessages.isEmpty)
    }

    @Test func aPermissionRequestForAnUnknownSessionAnswersCancelledWithOneWarning() async throws {
        let routed = await RoutedModel()
        let request = RequestPermissionRequest(
            options: [SessionModelFixtures.allowOption],
            sessionId: unknownSession,
            title: "Run the tool?"
        )

        let response = try await routed.agentConnection.requestPermission(request)

        #expect(response.outcome == .cancelled)
        #expect(routed.loggedMessages.count == 1)
    }

    // MARK: - Elicitations

    @Test func aSessionElicitationForAnOpenSessionLandsInItsModelAndTheAnswerReachesTheAgent() async throws {
        let routed = await RoutedModel()
        let session = routed.openTestSession()
        let request = ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))

        let call = try await routed.startElicitation(request, on: session)
        let pending = try #require(session.pendingElicitations.first)
        #expect(pending.request == request)
        session.acceptElicitation(pending.id, content: formContent)

        let response = try await call.value
        #expect(response == ElicitationResponseWire.acceptResponse(content: formContent))
        #expect(routed.loggedMessages.isEmpty)
    }

    @Test func aSessionElicitationForAnUnknownSessionAnswersCancelWithOneWarning() async throws {
        let routed = await RoutedModel()
        let scope = ElicitationSessionScope(sessionId: unknownSession)

        let response = try await routed.agentConnection.createElicitation(
            ElicitationFixtures.formRequest(scope: .session(scope))
        )

        #expect(response == ElicitationResponseWire.cancelResponse)
        #expect(routed.loggedMessages.count == 1)
    }

    @Test func aRequestScopedElicitationForARequestNotInFlightAnswersCancelWithOneWarning() async throws {
        let routed = await RoutedModel()
        let session = routed.openTestSession()

        let response = try await routed.agentConnection.createElicitation(
            ElicitationFixtures.formRequest(scope: .request(ElicitationFixtures.requestScope))
        )

        #expect(response == ElicitationResponseWire.cancelResponse)
        #expect(session.pendingElicitations.isEmpty)
        #expect(routed.model.pendingElicitations.isEmpty)
        #expect(routed.loggedMessages.count == 1)
    }

    @Test func anElicitationOfAnUnknownModeAnswersCancelWithOneWarning() async throws {
        let routed = await RoutedModel()
        _ = routed.openTestSession()
        let request = CreateElicitationRequest(
            message: ElicitationFixtures.formMessage,
            mode: .unknown("telepathy", .object([:]))
        )

        let response = try await routed.agentConnection.createElicitation(request)

        #expect(response == ElicitationResponseWire.cancelResponse)
        #expect(routed.loggedMessages.count == 1)
    }

    // MARK: - Elicitation complete

    @Test func aUrlElicitationCompleteClosesTheMatchingPendingElicitation() async throws {
        let routed = await RoutedModel()
        let session = routed.openTestSession()
        let request = ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        let call = try await routed.startElicitation(request, on: session)

        try await routed.agentConnection.elicitationComplete(
            CompleteElicitationNotification(elicitationId: ElicitationFixtures.urlID)
        )

        let response = try await call.value
        #expect(response == ElicitationResponseWire.acceptResponse(content: nil))
        #expect(session.pendingElicitations.isEmpty)
    }

    @Test func anElicitationCompleteThatNoSessionHoldsLeavesEachPendingElicitation() async throws {
        let routed = await RoutedModel()
        let session = routed.openTestSession()
        let request = ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        let call = try await routed.startElicitation(request, on: session)

        routed.model.completeElicitation(elicitationId: ElicitationId(rawValue: "elicit-other"))

        #expect(session.pendingElicitations.map(\.request) == [request])
        session.cancelAllPending()
        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
    }
}
