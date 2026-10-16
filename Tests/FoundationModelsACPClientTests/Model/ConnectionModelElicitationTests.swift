import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the request-scoped elicitations of `ConnectionModel`: an
// elicitation that names a request of the client is pending on the model
// while that request is in flight. The user resolves it, a url-mode
// `elicitation/complete` closes it, or the end of its request, a disconnect
// (from the agent or from the host), or a new connection cancels it.
//
// `InMemoryTransport.pair()` gives the real ACP wire, with a
// `ScriptedStubAgent` on the agent end. The stub holds `auth/login` behind a
// gate, so the login stays in flight. The agent handler cannot see the wire id
// of the login, so the test reads that id from the `started` event of the
// outgoing-request stream of the client. The test then sends the elicitation
// through the agent-side connection while the login waits, so the answer
// crosses the wire back to the agent.
//
// Each wait has a failure event (rule T1). A wait over the connection ends
// also on the close of the connection. A wait for a change that a started
// task must make ends also on the end of that task. Each test closes the
// harness in a `defer`, so the close runs also when the test body throws.

/// A model that is connected over an in-memory pair to a scripted stub agent
/// whose `auth/login` waits for a gate.
@MainActor
private struct LoginHarness {
    /// The model under test.
    let model: ConnectionModel

    /// The agent-side connection. Each test sends its elicitations through
    /// it.
    let agentConnection: AgentSideConnection

    /// The agent end of the pair. A close of it ends the input of the client.
    let agentEnd: InMemoryTransport

    /// The gate that holds each `auth/login` of the agent.
    let loginGate: UpdateGate

    /// The outgoing-request events of the client-side connection.
    private let requestEvents: AsyncStream<OutgoingRequestEvent>

    /// Connects a new model to a new stub agent.
    ///
    /// - Parameter loginError: The error the agent refuses each login with,
    ///   or `nil` to accept each login.
    init(loginError: RequestError? = nil) async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let loginGate = UpdateGate()
        self.agentEnd = agentEnd
        self.loginGate = loginGate
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: [],
                authMethods: [InitializeFixtures.agentMethod],
                loginError: loginError,
                loginGate: loginGate
            )
        }
        model = ConnectionModel()
        let connection = await model.connect(over: clientEnd)
        requestEvents = connection.subscribeToOutgoingRequests()
    }

    /// Whether the connection of the model closed. The failure event of a
    /// wait over the connection.
    ///
    /// The state `connecting` counts as open, because a test that makes a
    /// new connection goes through it.
    var connectionIsClosed: Bool {
        ![ConnectionState.connected, .connecting].contains(model.state)
    }

    /// Ends the work of the harness: opens the login gate, so no login of the
    /// agent waits for ever, and closes the connection of the model.
    ///
    /// Each test calls it in a `defer`, so it runs also when the test body
    /// throws. A second call changes nothing.
    func close() async {
        loginGate.open()
        await model.disconnect()
    }

    /// Initializes the model, starts a login through the model, and waits
    /// until the request is in flight.
    ///
    /// The model sends a login only for an `agent` method that the agent
    /// lists, so the initialize comes first.
    ///
    /// - Returns: The task of the login, and the wire id of its request.
    /// - Throws: The error of the initialize, ``WaitEndedOnFailure`` when the
    ///   login ended before it started, or an error when the event stream
    ///   ended before the login started.
    func startLogin() async throws -> (login: Task<Void, any Error>, requestId: RequestId) {
        _ = try await model.initialize(makeInitializeRequest())
        let login = Task { [model] in try await model.login(InitializeFixtures.login) }
        // The reader ends when the login starts, or when the event stream
        // ends. The end of the login is the failure event: the gate holds a
        // login that started, so a login that ended never started.
        let reader = Task { await loginRequestId() }
        defer { reader.cancel() }
        let readerEnd = TaskEnd(of: reader)
        let loginEnd = TaskEnd(of: login)
        try await waitUntil { readerEnd.hasEnded } orFailWhen: { loginEnd.hasEnded }
        let requestId = try #require(await reader.value)
        return (login, requestId)
    }

    /// Reads the outgoing-request events until the login starts.
    ///
    /// - Returns: The wire id of the login request, or `nil` when the stream
    ///   ended first.
    private func loginRequestId() async -> RequestId? {
        for await case .started(let id, let method) in requestEvents where method == ClientRequestSpan.Method.login {
            return id
        }
        return nil
    }

    /// Sends an elicitation that names a request, and waits until the model
    /// holds it as pending.
    ///
    /// - Parameters:
    ///   - requestId: The wire id of the request that the elicitation names.
    ///   - makeRequest: Builds the elicitation from its request scope.
    /// - Returns: The task of the agent's call.
    /// - Throws: ``WaitEndedOnFailure`` when the call ended before the model
    ///   held the elicitation.
    func startElicitation(
        naming requestId: RequestId,
        _ makeRequest: (ElicitationRequestScope) -> CreateElicitationRequest = { scope in
            ElicitationFixtures.formRequest(scope: .request(scope))
        }
    ) async throws -> Task<CreateElicitationResponse, any Error> {
        let request = makeRequest(ElicitationRequestScope(requestId: requestId))
        let before = model.pendingElicitations.count
        return try await ElicitationFixtures.start(request, over: agentConnection) { [model] in
            model.pendingElicitations.count == before + 1
        }
    }

    /// Opens the login gate, and waits until the login succeeded.
    ///
    /// - Parameter login: The task of the login.
    /// - Throws: Whatever the login threw.
    func finish(_ login: Task<Void, any Error>) async throws {
        loginGate.open()
        try await login.value
    }
}

/// Records that a test seam ran. A wait reads ``ran``, so the set of it ends
/// the wait.
@MainActor @Observable
private final class SeamProbe {
    /// Whether the seam ran.
    var ran = false
}

/// The request-scoped elicitation tests of the connection model, in one suite
/// so that `swift test --filter ConnectionModelElicitationTests` selects them.
@MainActor
@Suite
struct ConnectionModelElicitationTests {
    /// The form values that the user gives to an accepted form elicitation.
    private let formContent: JSONValue = .object(["name": .string("orion")])

    // MARK: - Pending state

    @Test func anElicitationDuringLoginIsPendingWithItsRequestIdAndMethod() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()

        let call = try await harness.startElicitation(naming: requestId)

        let pending = try #require(harness.model.pendingElicitations.first)
        #expect(harness.model.pendingElicitations.count == 1)
        #expect(pending.requestId == requestId)
        #expect(pending.requestMethod == ClientRequestSpan.Method.login)
        #expect(pending.sessionId == nil)
        harness.model.cancelElicitation(pending.id)
        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        try await harness.finish(login)
    }

    @Test func pendingRequestsGivesEachRequestScopedElicitationInArrivalOrder() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)

        let pending = try #require(harness.model.pendingElicitations.first)
        #expect(harness.model.pendingRequests == [.elicitation(pending)])

        harness.model.cancelElicitation(pending.id)
        #expect(harness.model.pendingRequests.isEmpty)
        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        try await harness.finish(login)
    }

    /// An elicitation with a smaller wire arrival number goes in front of the
    /// elicitation that got to the model before it (bug ^s39vtvg). The old
    /// code appends each elicitation, and gives the later one first.
    @Test func anElicitationWithASmallerArrivalGoesInFrontOfTheOneThatCameFirst() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let model = harness.model
        let request = ElicitationFixtures.formRequest(scope: .request(ElicitationRequestScope(requestId: requestId)))

        // Each wait ends also on the end of the task that must add the
        // elicitation: a task that ended did not add it.
        let later = Task { await model.awaitRequestScopedElicitation(request, requestId: requestId, arrival: 2) }
        let laterEnd = TaskEnd(of: later)
        try await waitUntil { model.pendingElicitations.count == 1 } orFailWhen: { laterEnd.hasEnded }
        let laterId = try #require(model.pendingElicitations.first?.id)
        let earlier = Task { await model.awaitRequestScopedElicitation(request, requestId: requestId, arrival: 1) }
        let earlierEnd = TaskEnd(of: earlier)
        try await waitUntil { model.pendingElicitations.count == 2 } orFailWhen: { earlierEnd.hasEnded }
        let earlierId = try #require(model.pendingElicitations.first { $0.id != laterId }?.id)

        #expect(model.pendingElicitations.map(\.id) == [earlierId, laterId])
        #expect(model.pendingRequests.map(\.id) == [earlierId, laterId])
        #expect(model.frontRequest?.id == earlierId)

        model.cancelElicitation(earlierId)
        model.cancelElicitation(laterId)
        _ = await (earlier.value, later.value)
        try await harness.finish(login)
    }

    /// The agent withdraws a request-scoped elicitation with
    /// `$/cancel_request`: the elicitation leaves the pending list, and the
    /// connection model keeps a record with the same id. The reason is `nil`,
    /// because the agent sent no `_meta`.
    @Test func anElicitationThatTheAgentWithdrawsGivesARecordOnTheConnection() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)
        let pending = try #require(harness.model.pendingRequests.first)

        call.cancel()
        try await waitUntil { !harness.model.withdrawnRequests.isEmpty } orFailWhen: { harness.connectionIsClosed }

        #expect(harness.model.pendingRequests.isEmpty)
        #expect(harness.model.withdrawnRequests.map(\.id) == [pending.id])
        #expect(harness.model.withdrawnRequests.first?.reason == nil)
        harness.model.dismissWithdrawn(pending.id)
        #expect(harness.model.withdrawnRequests.isEmpty)
        _ = try? await call.value
        try await harness.finish(login)
    }

    /// The agent withdraws a request-scoped elicitation, and the host makes a
    /// new connection before the task of the elicitation resumes. The record
    /// belongs to the old connection, so it must not come into the list of
    /// the new one. The seam fixes the order: the new connection comes after
    /// the wait ended and before the model decides on the record. The old
    /// code checks only that some connection is open, and makes the record.
    @Test func aWithdrawalOfAnOldConnectionGivesNoRecordOnTheNewConnection() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)
        let (newClientEnd, newAgentEnd) = InMemoryTransport.pair()
        defer { newAgentEnd.close() }
        let probe = SeamProbe()
        harness.model.afterRequestScopedElicitationWait = { [model = harness.model] in
            _ = await model.connect(over: newClientEnd)
            probe.ran = true
        }

        call.cancel()
        // The seam sets the state to connecting, so only a close is the
        // failure event of this wait.
        try await waitUntil { probe.ran } orFailWhen: { harness.connectionIsClosed }

        #expect(harness.model.withdrawnRequests.isEmpty)
        _ = try? await call.value
        harness.loginGate.open()
        _ = try? await login.value
    }

    // MARK: - Front

    /// Starts a login and three elicitations that name it, in the order E1,
    /// E2, E3.
    ///
    /// - Parameter harness: The harness of the test.
    /// - Returns: The login, the calls of the agent, and the three requests.
    private func startThreeElicitations(
        on harness: LoginHarness
    ) async throws -> (login: Task<Void, any Error>, calls: [Task<CreateElicitationResponse, any Error>], requests: [PendingRequest]) {
        let (login, requestId) = try await harness.startLogin()
        var calls: [Task<CreateElicitationResponse, any Error>] = []
        for _ in 0..<3 {
            calls.append(try await harness.startElicitation(naming: requestId))
        }
        return (login, calls, harness.model.pendingRequests)
    }

    /// Cancels each pending elicitation, waits for each call of the agent, and
    /// ends the login.
    ///
    /// - Parameters:
    ///   - harness: The harness of the test.
    ///   - login: The task of the login.
    ///   - calls: The calls of the agent.
    private func finish(
        _ harness: LoginHarness,
        login: Task<Void, any Error>,
        calls: [Task<CreateElicitationResponse, any Error>]
    ) async throws {
        for pending in harness.model.pendingElicitations {
            harness.model.cancelElicitation(pending.id)
        }
        for call in calls {
            _ = try await call.value
        }
        try await harness.finish(login)
    }

    @Test func theFrontIsTheOldestRequestAndANewRequestGoesAtTheBack() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        #expect(harness.model.frontRequest == nil)
        let (login, requestId) = try await harness.startLogin()
        let first = try await harness.startElicitation(naming: requestId)
        let oldest = try #require(harness.model.pendingRequests.first)

        let second = try await harness.startElicitation(naming: requestId)

        #expect(harness.model.frontRequestID == nil)
        #expect(harness.model.frontRequest == oldest)
        #expect(harness.model.pendingRequests.last != oldest)
        try await finish(harness, login: login, calls: [first, second])
    }

    @Test func bringingARequestToTheFrontKeepsTheOrder() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, calls, requests) = try await startThreeElicitations(on: harness)

        harness.model.bringToFront(requests[2].id)

        #expect(harness.model.frontRequestID == requests[2].id)
        #expect(harness.model.frontRequest == requests[2])
        #expect(harness.model.pendingRequests == requests)
        try await finish(harness, login: login, calls: calls)
    }

    @Test func anUnknownIdChangesNothingOnTheConnection() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, calls, requests) = try await startThreeElicitations(on: harness)
        harness.model.bringToFront(requests[1].id)

        harness.model.bringToFront(UUID())

        #expect(harness.model.frontRequest == requests[1])
        try await finish(harness, login: login, calls: calls)
    }

    @Test func anAnsweredFrontMovesTheFrontToTheOldestRequestThatStays() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, calls, requests) = try await startThreeElicitations(on: harness)
        harness.model.bringToFront(requests[2].id)

        harness.model.declineElicitation(requests[2].id)

        #expect(harness.model.frontRequestID == nil)
        #expect(harness.model.frontRequest == requests[0])
        try await finish(harness, login: login, calls: calls)
    }

    @Test func aCancelledFrontMovesTheFrontToTheOldestRequestThatStays() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, calls, requests) = try await startThreeElicitations(on: harness)
        harness.model.bringToFront(requests[0].id)

        harness.model.cancelElicitation(requests[0].id)

        #expect(harness.model.frontRequestID == nil)
        #expect(harness.model.frontRequest == requests[1])
        try await finish(harness, login: login, calls: calls)
    }

    @Test func bringingARequestToTheFrontFiresTheObservationOfTheConnectionFront() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, calls, requests) = try await startThreeElicitations(on: harness)

        let fires = observationFires(reading: { _ = harness.model.frontRequest }) {
            harness.model.bringToFront(requests[1].id)
        }

        #expect(fires)
        try await finish(harness, login: login, calls: calls)
    }

    @Test func aNewConnectionClearsTheFront() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, calls, requests) = try await startThreeElicitations(on: harness)
        harness.model.bringToFront(requests[1].id)
        let (clientEnd, _) = InMemoryTransport.pair()

        _ = await harness.model.connect(over: clientEnd)

        #expect(harness.model.frontRequestID == nil)
        #expect(harness.model.frontRequest == nil)
        for call in calls {
            _ = try await call.value
        }
        try await harness.finish(login)
    }

    // MARK: - Replies

    @Test func acceptResumesTheAgentOneTimeWithTheContent() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)
        let pending = try #require(harness.model.pendingElicitations.first)

        harness.model.acceptElicitation(pending.id, content: formContent)
        // A second resolution of the same id changes nothing, so the call
        // resumes one time, with the first answer.
        harness.model.cancelElicitation(pending.id)

        #expect(try await call.value == ElicitationResponseWire.acceptResponse(content: formContent))
        #expect(harness.model.pendingElicitations.isEmpty)
        try await harness.finish(login)
    }

    @Test func declineResumesTheAgentOneTimeWithTheDeclineAction() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)
        let pending = try #require(harness.model.pendingElicitations.first)

        harness.model.declineElicitation(pending.id)
        harness.model.acceptElicitation(pending.id, content: formContent)

        #expect(try await call.value == ElicitationResponseWire.declineResponse)
        #expect(harness.model.pendingElicitations.isEmpty)
        try await harness.finish(login)
    }

    @Test func cancelResumesTheAgentOneTimeWithTheCancelAction() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)
        let pending = try #require(harness.model.pendingElicitations.first)

        harness.model.cancelElicitation(pending.id)
        harness.model.declineElicitation(pending.id)

        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        #expect(harness.model.pendingElicitations.isEmpty)
        try await harness.finish(login)
    }

    /// A cancel of the work of a session answers only the elicitations of
    /// that session. A request-scoped elicitation belongs to a client request
    /// (here `auth/login`), so it stays pending on the connection model.
    @Test func aSessionCancelKeepsTheRequestScopedElicitations() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)
        let session = harness.model.makeSessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        harness.model.register(session)

        try await session.cancel()

        let pending = try #require(harness.model.pendingElicitations.first)
        #expect(pending.requestId == requestId)
        harness.model.cancelElicitation(pending.id)
        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        try await harness.finish(login)
    }

    // MARK: - Elicitation complete

    @Test func aUrlElicitationCompleteClosesTheMatchingRequestScopedElicitation() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId) { scope in
            ElicitationFixtures.urlRequest(scope: .request(scope))
        }

        try await harness.agentConnection.elicitationComplete(
            CompleteElicitationNotification(elicitationId: ElicitationFixtures.urlID)
        )

        #expect(try await call.value == ElicitationResponseWire.acceptResponse(content: nil))
        #expect(harness.model.pendingElicitations.isEmpty)
        try await harness.finish(login)
    }

    // MARK: - URL completion

    /// Starts a login and a url-mode elicitation that names it, accepts the
    /// elicitation, and waits for the answer of the agent's call.
    ///
    /// - Parameter harness: The harness of the test.
    /// - Returns: The login, and the accepted elicitation.
    private func acceptRequestScopedURLElicitation(
        on harness: LoginHarness
    ) async throws -> (login: Task<Void, any Error>, accepted: PendingElicitation) {
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId) { scope in
            ElicitationFixtures.urlRequest(scope: .request(scope))
        }
        let pending = try #require(harness.model.pendingElicitations.first)
        harness.model.acceptElicitation(pending.id)
        #expect(try await call.value == ElicitationResponseWire.acceptResponse(content: nil))
        return (login, pending)
    }

    @Test func anAcceptedRequestScopedUrlElicitationWaitsForItsCompletion() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }

        let (login, accepted) = try await acceptRequestScopedURLElicitation(on: harness)

        #expect(harness.model.pendingElicitations.isEmpty)
        #expect(harness.model.awaitingURLCompletions == [accepted])
        try await harness.finish(login)
    }

    @Test func theElicitationCompleteOfTheAgentRemovesTheAwaitingItem() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, _) = try await acceptRequestScopedURLElicitation(on: harness)

        try await harness.agentConnection.elicitationComplete(
            CompleteElicitationNotification(elicitationId: ElicitationFixtures.urlID)
        )

        try await waitUntil { harness.model.awaitingURLCompletions.isEmpty } orFailWhen: { harness.connectionIsClosed }
        try await harness.finish(login)
    }

    @Test func stopWaitingRemovesTheRequestScopedAwaitingItem() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, accepted) = try await acceptRequestScopedURLElicitation(on: harness)

        harness.model.stopWaiting(accepted.id)

        #expect(harness.model.awaitingURLCompletions.isEmpty)
        try await harness.finish(login)
    }

    @Test func theFinishOfItsRequestRemovesTheAwaitingItem() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, _) = try await acceptRequestScopedURLElicitation(on: harness)

        try await harness.finish(login)

        try await waitUntil { harness.model.awaitingURLCompletions.isEmpty } orFailWhen: { harness.connectionIsClosed }
    }

    @Test func aNewConnectionRemovesEachAwaitingItem() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, _) = try await acceptRequestScopedURLElicitation(on: harness)
        let (clientEnd, _) = InMemoryTransport.pair()

        _ = await harness.model.connect(over: clientEnd)

        #expect(harness.model.awaitingURLCompletions.isEmpty)
        harness.loginGate.open()
        _ = try? await login.value
    }

    /// The disconnect is the behavior under test, so the body closes the
    /// connection itself. The `defer` closes it only when the body throws
    /// before the disconnect.
    @Test func aDisconnectRemovesEachAwaitingItem() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, _) = try await acceptRequestScopedURLElicitation(on: harness)

        await harness.model.disconnect()

        #expect(harness.model.awaitingURLCompletions.isEmpty)
        harness.loginGate.open()
        _ = try? await login.value
    }

    @Test func theConnectionRoutesACompleteToTheAwaitingItemOfASession() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let session = harness.model.makeSessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        harness.model.register(session)
        let request = ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        let call = Task { await session.awaitElicitation(request) }
        // The session has a fake sender, so the end of the task that must
        // add the elicitation is the failure event.
        let callEnd = TaskEnd(of: call)
        try await waitUntil { !session.pendingElicitations.isEmpty } orFailWhen: { callEnd.hasEnded }
        session.acceptElicitation(try #require(session.pendingElicitations.first).id)
        _ = await call.value

        let matched = harness.model.completeElicitation(elicitationId: ElicitationFixtures.urlID)

        #expect(matched)
        #expect(session.awaitingURLCompletions.isEmpty)
    }

    // MARK: - End of the request

    @Test func aSuccessfulLoginRemovesItsElicitationAndTheAgentGetsCancel() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)

        try await harness.finish(login)

        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        #expect(harness.model.pendingElicitations.isEmpty)
    }

    @Test func aRefusedLoginRemovesItsElicitationAndTheAgentGetsCancel() async throws {
        let harness = await LoginHarness(loginError: InitializeFixtures.loginRefusal)
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)

        await #expect(throws: InitializeFixtures.loginRefusal) {
            try await harness.finish(login)
        }

        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        #expect(harness.model.pendingElicitations.isEmpty)
    }

    // MARK: - Close

    /// Starts a login and an elicitation that names it, closes the connection
    /// with `close`, and checks that the close cancels the elicitation and
    /// fails the login.
    ///
    /// The close is the behavior under test. The `defer` closes the harness
    /// only when the body throws before `close`.
    ///
    /// - Parameter close: Closes the connection of the harness, and waits
    ///   until the model is disconnected.
    /// - Throws: Whatever the start of the login, the elicitation, or `close`
    ///   threw.
    private func expectACloseCancelsTheRequestScopedElicitation(
        _ close: (LoginHarness) async throws -> Void
    ) async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)

        try await close(harness)

        #expect(harness.model.pendingElicitations.isEmpty)
        await #expect(throws: ConnectionError.closed) {
            try await login.value
        }
        // The client end closed, so no answer can reach the agent. The test
        // ends the agent's call and the held login itself.
        call.cancel()
        harness.loginGate.open()
    }

    @Test func aDisconnectCancelsEachRequestScopedElicitation() async throws {
        try await expectACloseCancelsTheRequestScopedElicitation { harness in
            harness.agentEnd.close()
            // A failed read is the failure event: it closes the connection
            // with a different state.
            try await waitUntil { harness.model.state == .disconnected } orFailWhen: {
                guard case .failed = harness.model.state else { return false }
                return true
            }
        }
    }

    @Test func aDisconnectByTheHostCancelsEachRequestScopedElicitation() async throws {
        try await expectACloseCancelsTheRequestScopedElicitation { harness in
            await harness.model.disconnect()
            // The call returns only after the close, so the state is final at once.
            #expect(harness.model.state == .disconnected)
        }
    }

    @Test func aNewConnectionCancelsEachRequestScopedElicitationOfTheLastOne() async throws {
        let harness = await LoginHarness()
        defer { await harness.close() }
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)
        let (clientEnd, _) = InMemoryTransport.pair()

        _ = await harness.model.connect(over: clientEnd)

        #expect(harness.model.pendingElicitations.isEmpty)
        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        try await harness.finish(login)
    }
}
