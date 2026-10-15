import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the user presence setting (elicitation-plan task 28): the
// `elicitation` capability that `initialize` sends decides whether the model
// routes an elicitation of the agent to the user, or answers it at once with
// `cancel` and a reason in `_meta`.
//
// `InMemoryTransport.pair()` gives the real ACP wire, with a
// `ScriptedStubAgent` on the agent end. Each test sends its elicitation through
// the agent-side connection, so the answer crosses the wire back to the agent.
// Each step waits on the answer or on the observable pending state, so the
// order is fixed. No test uses a clock, a sleep, a poll or a time limit.

/// A model that can connect more than one time to a scripted stub agent, and
/// that logs to a test logger.
@MainActor
private struct PresenceHarness {
    /// The model under test.
    let model: ConnectionModel

    /// The messages that the model logged, in order.
    private let messages: ThreadSafeBuffer<String>

    /// The messages that the model logged, in order.
    var loggedMessages: [String] {
        messages.elements
    }

    /// Makes a model with no connection.
    init() {
        let messages = ThreadSafeBuffer<String>()
        self.messages = messages
        model = ConnectionModel(logger: ACPLogger { messages.append($0) })
    }

    /// Connects the model to a new stub agent.
    ///
    /// - Returns: The agent-side connection. The test sends its requests
    ///   through it.
    func connect() async -> AgentSideConnection {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            ScriptedStubAgent(connection: connection, session: testSession, script: [])
        }
        _ = await model.connect(over: clientEnd)
        return agentConnection
    }

    /// Sends `initialize` with the given client capabilities.
    ///
    /// - Parameter capabilities: The capabilities that the request sends.
    func initialize(_ capabilities: ClientCapabilities) async throws {
        _ = try await model.initialize(
            InitializeRequest(
                info: Implementation(name: "test-client", version: "1.0.0"),
                protocolVersion: ACPClient.supportedProtocolVersion,
                capabilities: capabilities
            )
        )
    }

    /// Makes the model of the test session and opens it.
    ///
    /// - Returns: The open session model.
    func openTestSession() -> SessionModel {
        let session = model.makeSessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        model.register(session)
        return session
    }
}

/// The user presence tests, in one suite so that `swift test --filter
/// ElicitationUserPresenceTests` selects them.
@MainActor
@Suite
struct ElicitationUserPresenceTests {
    /// The client capabilities that advertise only the form mode.
    private let formOnly = ClientCapabilities(
        elicitation: ElicitationCapabilities(form: ElicitationFormCapabilities())
    )

    /// Gives the reason in the `_meta` of an elicitation response.
    ///
    /// - Parameter response: The response as the agent received it.
    /// - Returns: The string under ``ACPClient/elicitationReasonMetaKey`` in
    ///   `_meta`, or `nil`.
    private func metaReason(of response: CreateElicitationResponse) -> String? {
        guard case .object(let members) = response,
            case .object(let meta)? = members["_meta"],
            case .string(let reason)? = meta[ACPClient.elicitationReasonMetaKey]
        else { return nil }
        return reason
    }

    /// Gives the action of an elicitation response.
    ///
    /// - Parameter response: The response as the agent received it.
    /// - Returns: The `action` member, or `nil`.
    private func action(of response: CreateElicitationResponse) -> String? {
        guard case .object(let members) = response, case .string(let action)? = members["action"] else { return nil }
        return action
    }

    // MARK: - Headless

    @Test func aHeadlessClientCancelsASessionElicitationAtOnceWithTheNoUserReason() async throws {
        let harness = PresenceHarness()
        let agent = await harness.connect()
        try await harness.initialize(ACPClient.capabilities(for: .headless))
        let session = harness.openTestSession()

        let response = try await agent.createElicitation(
            ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))
        )

        #expect(action(of: response) == "cancel")
        #expect(metaReason(of: response) == "no user is present")
        #expect(response == ElicitationResponseWire.cancelResponse(reason: ACPClient.noUserPresentReason))
        #expect(session.pendingElicitations.isEmpty)
        #expect(harness.loggedMessages.count == 1)
    }

    @Test func aHeadlessClientCancelsARequestScopedElicitationAtOnceWithTheNoUserReason() async throws {
        let harness = PresenceHarness()
        let agent = await harness.connect()
        try await harness.initialize(ACPClient.capabilities(for: .headless))

        let response = try await agent.createElicitation(
            ElicitationFixtures.urlRequest(scope: .request(ElicitationFixtures.requestScope))
        )

        #expect(action(of: response) == "cancel")
        #expect(metaReason(of: response) == ACPClient.noUserPresentReason)
        #expect(harness.model.pendingElicitations.isEmpty)
        #expect(harness.loggedMessages.count == 1)
    }

    // MARK: - One mode only

    @Test func aClientWithTheFormModeOnlyCancelsAUrlElicitationAndRoutesAFormElicitation() async throws {
        let harness = PresenceHarness()
        let agent = await harness.connect()
        try await harness.initialize(formOnly)
        let session = harness.openTestSession()

        let refused = try await agent.createElicitation(
            ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        )
        #expect(action(of: refused) == "cancel")
        #expect(metaReason(of: refused) == ACPClient.unadvertisedElicitationModeReason)
        #expect(session.pendingElicitations.isEmpty)

        let routed = try await ElicitationFixtures.start(
            ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope)),
            over: agent
        ) { !session.pendingElicitations.isEmpty }
        session.cancelAllPending()
        let cancelled = try await routed.value
        #expect(cancelled == ElicitationResponseWire.cancelResponse)
        #expect(metaReason(of: cancelled) == nil)
        #expect(harness.loggedMessages.count == 1)
    }

    // MARK: - Interactive

    @Test func anInteractiveClientRoutesTheElicitationToTheUser() async throws {
        let harness = PresenceHarness()
        let agent = await harness.connect()
        try await harness.initialize(ACPClient.capabilities(for: .interactive))
        let session = harness.openTestSession()
        let content: JSONValue = .object(["name": .string("orion")])

        let call = try await ElicitationFixtures.start(
            ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope)),
            over: agent
        ) { !session.pendingElicitations.isEmpty }
        let pending = try #require(session.pendingElicitations.first)
        session.acceptElicitation(pending.id, content: content)

        #expect(try await call.value == ElicitationResponseWire.acceptResponse(content: content))
        #expect(harness.loggedMessages.isEmpty)
    }

    // MARK: - A new connection

    @Test func aNewConnectionForgetsTheHeadlessInitialize() async throws {
        let harness = PresenceHarness()
        _ = await harness.connect()
        try await harness.initialize(ACPClient.capabilities(for: .headless))

        // The second connection sends no `initialize`, so the model refuses
        // nothing and routes the elicitation as before.
        let agent = await harness.connect()
        let session = harness.openTestSession()
        let call = try await ElicitationFixtures.start(
            ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope)),
            over: agent
        ) { !session.pendingElicitations.isEmpty }
        session.cancelAllPending()

        #expect(try await call.value == ElicitationResponseWire.cancelResponse)
        #expect(harness.loggedMessages.isEmpty)
    }
}
