import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// These tests cover milestone M7: pending elicitations as bindable state.
// An `elicitation/create` call from the agent becomes observable pending
// state on the client container. An answer from the UI resolves the
// agent's in-flight call with the spec's action object. Cancellation,
// agent withdrawal, connection drop, and `elicitation/complete` clear
// the pending state and release each continuation.

/// The form schema that each test form request carries: one required
/// "name" string.
private let nameSchema = ElicitationSchema(
    properties: .object(["name": .object(["type": .string("string")])]),
    required: ["name"]
)

/// Makes a form-mode elicitation request scoped to the test session.
///
/// - Parameter message: The message of the elicitation prompt.
/// - Returns: The request, with the one-field test schema.
private func formElicitationRequest(
    message: String = "Name the deployment"
) -> CreateElicitationRequest {
    CreateElicitationRequest(
        message: message,
        mode: .form(
            ElicitationFormMode(
                requestedSchema: nameSchema,
                scope: .session(ElicitationSessionScope(sessionId: testSession))
            )
        )
    )
}

/// The elicitation id that each test URL request carries.
private let urlElicitationID = ElicitationId(rawValue: "elicit-1")

/// The URL that each test URL request points at.
private let elicitationURLString = "https://example.test/verify"

/// Makes a url-mode elicitation request scoped to a JSON-RPC request.
///
/// The request scope models an elicitation that arrives before any
/// session exists, for example during authentication.
///
/// - Returns: The request.
private func urlElicitationRequest() -> CreateElicitationRequest {
    CreateElicitationRequest(
        message: "Finish sign-in in the browser",
        mode: .url(
            ElicitationUrlMode(
                elicitationId: urlElicitationID,
                url: elicitationURLString,
                scope: .request(ElicitationRequestScope(requestId: .string("req-1")))
            )
        )
    )
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aFormElicitationAppearsAsPendingStateAndAcceptingResolvesTheAgentCall() async throws {
    let model = SwiftUIACPClient()
    let request = formElicitationRequest()

    let responseTask = Task { try await model.createElicitation(request) }
    try await waitUntil { !model.pendingElicitations.isEmpty }

    // The pending state carries the whole request, so the UI can render
    // the form from the requested schema. The session-scoped request
    // exposes its session id for a per-session filter.
    let pending = try #require(model.pendingElicitations.first)
    #expect(pending.request == request)
    #expect(pending.sessionId == testSession)

    // The accepted values match the requested schema: one "name" string.
    let values: JSONValue = .object(["name": .string("orion")])
    model.acceptElicitation(pending.id, content: values)

    let response = try await responseTask.value
    #expect(response == .object(["action": .string("accept"), "content": values]))
    #expect(model.pendingElicitations.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func decliningAPendingElicitationResolvesTheAgentCallWithDecline() async throws {
    let model = SwiftUIACPClient()

    let responseTask = Task { try await model.createElicitation(formElicitationRequest()) }
    try await waitUntil { !model.pendingElicitations.isEmpty }

    let pending = try #require(model.pendingElicitations.first)
    model.declineElicitation(pending.id)

    let response = try await responseTask.value
    #expect(response == .object(["action": .string("decline")]))
    #expect(model.pendingElicitations.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func cancellingFromTheUIResolvesTheAgentCallWithCancel() async throws {
    let model = SwiftUIACPClient()

    let responseTask = Task { try await model.createElicitation(formElicitationRequest()) }
    try await waitUntil { !model.pendingElicitations.isEmpty }

    let pending = try #require(model.pendingElicitations.first)
    model.cancelElicitation(pending.id)

    let response = try await responseTask.value
    #expect(response == .object(["action": .string("cancel")]))
    #expect(model.pendingElicitations.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func cancellingTheAgentCallClearsThePendingElicitationAndResumesTheContinuation() async throws {
    let model = SwiftUIACPClient()

    let responseTask = Task { try await model.createElicitation(formElicitationRequest()) }
    try await waitUntil { !model.pendingElicitations.isEmpty }

    // Task cancellation is how the connection delivers the agent's
    // withdrawal of the elicitation.
    responseTask.cancel()

    // The await below returns only when the continuation resumed. A
    // completed task therefore proves that no continuation leaks; a
    // leaked continuation makes the test time out.
    let response = try await responseTask.value
    #expect(response == .object(["action": .string("cancel")]))
    #expect(model.pendingElicitations.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func connectionDropWhilePendingClearsElicitationStateCleanly() async throws {
    let model = SwiftUIACPClient()
    model.connectionState = .connected

    let responseTask = Task { try await model.createElicitation(formElicitationRequest()) }
    try await waitUntil { !model.pendingElicitations.isEmpty }

    model.connectionState = .disconnected

    let response = try await responseTask.value
    #expect(response == .object(["action": .string("cancel")]))
    #expect(model.pendingElicitations.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPendingUrlElicitationShowsTheTargetHostForTheConsentGate() async throws {
    let model = SwiftUIACPClient()

    let responseTask = Task { try await model.createElicitation(urlElicitationRequest()) }
    try await waitUntil { !model.pendingElicitations.isEmpty }

    // The container never navigates on its own. It shows the URL and the
    // target host, so the UI can get the user's consent before it
    // navigates. The request-scoped elicitation has no session.
    let pending = try #require(model.pendingElicitations.first)
    #expect(pending.sessionId == nil)
    #expect(pending.elicitationId == urlElicitationID)
    #expect(pending.url == URL(string: elicitationURLString))
    #expect(pending.targetHost == "example.test")

    model.cancelElicitation(pending.id)
    _ = try await responseTask.value
}

@MainActor @Test(.timeLimit(.minutes(1)))
func elicitationCompleteClosesThePendingUrlPromptWithAcceptAndNoContent() async throws {
    let model = SwiftUIACPClient()

    let responseTask = Task { try await model.createElicitation(urlElicitationRequest()) }
    try await waitUntil { !model.pendingElicitations.isEmpty }

    await model.elicitationComplete(
        CompleteElicitationNotification(elicitationId: urlElicitationID)
    )

    // The URL flow returned its data out of band. The response carries
    // the accept action and no content, so no credentials go back over
    // ACP.
    let response = try await responseTask.value
    #expect(response == .object(["action": .string("accept")]))
    #expect(model.pendingElicitations.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func elicitationCompleteWithAnUnknownIdChangesNothing() async throws {
    let model = SwiftUIACPClient()

    let responseTask = Task { try await model.createElicitation(urlElicitationRequest()) }
    try await waitUntil { !model.pendingElicitations.isEmpty }

    await model.elicitationComplete(
        CompleteElicitationNotification(elicitationId: ElicitationId(rawValue: "other"))
    )
    #expect(model.pendingElicitations.count == 1)

    let pending = try #require(model.pendingElicitations.first)
    model.cancelElicitation(pending.id)
    _ = try await responseTask.value
}

@MainActor @Test(.timeLimit(.minutes(1)))
func theSessionFilterReturnsSessionScopedElicitationsOnly() async throws {
    let model = SwiftUIACPClient()

    let formTask = Task { try await model.createElicitation(formElicitationRequest()) }
    try await waitUntil { model.pendingElicitations.count == 1 }
    let urlTask = Task { try await model.createElicitation(urlElicitationRequest()) }
    try await waitUntil { model.pendingElicitations.count == 2 }

    // Both elicitations stay pending together, in arrival order. The
    // per-session filter returns the session-scoped one only.
    let formID = model.pendingElicitations[0].id
    #expect(model.pendingElicitations(for: testSession).map(\.id) == [formID])

    // Each elicitation resolves independently of the other.
    let urlID = model.pendingElicitations[1].id
    model.cancelElicitation(urlID)
    _ = try await urlTask.value
    #expect(model.pendingElicitations.map(\.id) == [formID])

    model.declineElicitation(formID)
    _ = try await formTask.value
    #expect(model.pendingElicitations.isEmpty)
}

/// A stub agent that sends one form elicitation during its one prompt
/// turn.
///
/// After the client answers, the stub reports the response's action back
/// as an agent message, so the test can read the outcome from the
/// observable session state.
private final class ElicitationStubAgent: Agent {
    /// The connection back to the client.
    private let connection: AgentSideConnection

    /// Creates the stub.
    ///
    /// - Parameter connection: The connection back to the client.
    init(connection: AgentSideConnection) {
        self.connection = connection
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "elicitation-stub-agent", version: "1.0.0"),
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
        let response = try await connection.createElicitation(formElicitationRequest())
        let actionText: String
        if case .object(let members) = response, case .string(let action) = members["action"] {
            actionText = action
        } else {
            actionText = "malformed"
        }
        try await connection.sessionUpdate(
            UpdateSessionNotification(
                sessionId: testSession,
                update: .agentMessage(
                    AgentMessage(
                        messageId: MessageId(rawValue: "outcome-1"),
                        content: .value([textBlock(actionText)])
                    )
                )
            )
        )
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aStubAgentsFormElicitationRoundTripsOverTheWire() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let model = SwiftUIACPClient()
    let connection = await ClientSideConnection(stream: clientEnd) { _ in model }
    let agentConnection = await AgentSideConnection(stream: agentEnd) { agentSide in
        ElicitationStubAgent(connection: agentSide)
    }

    async let promptResult = connection.prompt(
        PromptRequest(prompt: [textBlock("go")], sessionId: testSession)
    )

    // The agent's elicitation appears as pending state on the client.
    try await waitUntil { !model.pendingElicitations.isEmpty }
    let pending = try #require(model.pendingElicitations.first)
    #expect(pending.request.message == "Name the deployment")

    // The answer resolves the agent's in-flight request, and the agent
    // reports the accept action back.
    model.acceptElicitation(pending.id, content: .object(["name": .string("orion")]))
    _ = try await promptResult

    let state = model.session(for: testSession)
    #expect(state.messageContent(for: MessageId(rawValue: "outcome-1")) == [textBlock("accept")])
    #expect(model.pendingElicitations.isEmpty)

    await connection.close()
    withExtendedLifetime(agentConnection) {}
}
