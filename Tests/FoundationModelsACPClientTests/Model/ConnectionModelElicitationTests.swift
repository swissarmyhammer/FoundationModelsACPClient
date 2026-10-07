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

    /// Initializes the model, starts a login through the model, and waits
    /// until the request is in flight.
    ///
    /// The model sends a login only for an `agent` method that the agent
    /// lists, so the initialize comes first.
    ///
    /// - Returns: The task of the login, and the wire id of its request.
    /// - Throws: The error of the initialize, or an error when the event
    ///   stream ended before the login started.
    func startLogin() async throws -> (login: Task<Void, any Error>, requestId: RequestId) {
        _ = try await model.initialize(makeInitializeRequest())
        let login = Task { [model] in try await model.login(InitializeFixtures.login) }
        let requestId = try #require(await loginRequestId())
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
    /// - Throws: `CancellationError` when the test time limit cancels the wait.
    func startElicitation(
        naming requestId: RequestId,
        _ makeRequest: (ElicitationRequestScope) -> CreateElicitationRequest = { scope in
            ElicitationFixtures.formRequest(scope: .request(scope))
        }
    ) async throws -> Task<CreateElicitationResponse, any Error> {
        let request = makeRequest(ElicitationRequestScope(requestId: requestId))
        return try await ElicitationFixtures.start(request, over: agentConnection) { [model] in
            !model.pendingElicitations.isEmpty
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

/// The request-scoped elicitation tests of the connection model, in one suite
/// so that `swift test --filter ConnectionModelElicitationTests` selects them.
/// A wait for an answer that never comes would suspend for ever, so the suite
/// has a time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionModelElicitationTests {
    /// The form values that the user gives to an accepted form elicitation.
    private let formContent: JSONValue = .object(["name": .string("orion")])

    // MARK: - Pending state

    @Test func anElicitationDuringLoginIsPendingWithItsRequestIdAndMethod() async throws {
        let harness = await LoginHarness()
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

    // MARK: - Replies

    @Test func acceptResumesTheAgentOneTimeWithTheContent() async throws {
        let harness = await LoginHarness()
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
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)
        let pending = try #require(harness.model.pendingElicitations.first)

        harness.model.cancelElicitation(pending.id)
        harness.model.declineElicitation(pending.id)

        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        #expect(harness.model.pendingElicitations.isEmpty)
        try await harness.finish(login)
    }

    // MARK: - Elicitation complete

    @Test func aUrlElicitationCompleteClosesTheMatchingRequestScopedElicitation() async throws {
        let harness = await LoginHarness()
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

    // MARK: - End of the request

    @Test func aSuccessfulLoginRemovesItsElicitationAndTheAgentGetsCancel() async throws {
        let harness = await LoginHarness()
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)

        try await harness.finish(login)

        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        #expect(harness.model.pendingElicitations.isEmpty)
    }

    @Test func aRefusedLoginRemovesItsElicitationAndTheAgentGetsCancel() async throws {
        let harness = await LoginHarness(loginError: InitializeFixtures.loginRefusal)
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
    /// - Parameter close: Closes the connection of the harness, and waits
    ///   until the model is disconnected.
    /// - Throws: Whatever the start of the login, the elicitation, or `close`
    ///   threw.
    private func expectACloseCancelsTheRequestScopedElicitation(
        _ close: (LoginHarness) async throws -> Void
    ) async throws {
        let harness = await LoginHarness()
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
            try await waitUntil { harness.model.state == .disconnected }
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
        let (login, requestId) = try await harness.startLogin()
        let call = try await harness.startElicitation(naming: requestId)
        let (clientEnd, _) = InMemoryTransport.pair()

        _ = await harness.model.connect(over: clientEnd)

        #expect(harness.model.pendingElicitations.isEmpty)
        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        try await harness.finish(login)
    }
}
