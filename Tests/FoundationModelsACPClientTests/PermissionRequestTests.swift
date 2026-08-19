import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// These tests cover milestone M3: pending permission requests as bindable
// state. A permission request from the agent becomes observable pending
// state. An answer from the UI resolves the agent's in-flight call with
// the selected option. Cancellation, agent withdrawal, and connection
// drop clear the pending state and release each continuation.

/// The "allow" option that each test request offers.
private let allowOption = PermissionOption(
    kind: .allowOnce,
    name: "Allow",
    optionId: PermissionOptionId(rawValue: "allow-once")
)

/// The "reject" option that each test request offers.
private let rejectOption = PermissionOption(
    kind: .rejectOnce,
    name: "Reject",
    optionId: PermissionOptionId(rawValue: "reject-once")
)

/// Makes a permission request for the test session.
///
/// - Parameter title: The title of the permission prompt.
/// - Returns: The request, with the two test options.
private func permissionRequest(title: String = "Run the tool?") -> RequestPermissionRequest {
    RequestPermissionRequest(options: [allowOption, rejectOption], sessionId: testSession, title: title)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func answeringAPendingPermissionRequestResolvesTheAgentCallWithTheSelectedOption() async throws {
    let model = SwiftUIACPClient()
    let request = permissionRequest()

    let responseTask = Task { try await model.requestPermission(request) }
    let state = model.session(for: testSession)
    try await waitUntil { !state.pendingPermissionRequests.isEmpty }

    // The pending state carries the whole request, so the UI can show the
    // options and the subject context.
    let pending = try #require(state.pendingPermissionRequests.first)
    #expect(pending.request == request)
    #expect(pending.request.options == [allowOption, rejectOption])

    state.answerPermissionRequest(pending.id, with: rejectOption.optionId)

    let response = try await responseTask.value
    #expect(response.outcome == .selected(SelectedPermissionOutcome(optionId: rejectOption.optionId)))
    #expect(state.pendingPermissionRequests.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func cancellingTheAgentRequestClearsThePromptAndResumesTheContinuation() async throws {
    let model = SwiftUIACPClient()

    let responseTask = Task { try await model.requestPermission(permissionRequest()) }
    let state = model.session(for: testSession)
    try await waitUntil { !state.pendingPermissionRequests.isEmpty }

    // Task cancellation is how the connection delivers the agent's
    // withdrawal of the request.
    responseTask.cancel()

    // The await below returns only when the continuation resumed. A
    // completed task therefore proves that no continuation leaks; a
    // leaked continuation makes the test time out.
    let response = try await responseTask.value
    #expect(response.outcome == .cancelled)
    #expect(state.pendingPermissionRequests.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func cancellingFromTheUIAnswersCancelledAndClearsThePrompt() async throws {
    let model = SwiftUIACPClient()

    let responseTask = Task { try await model.requestPermission(permissionRequest()) }
    let state = model.session(for: testSession)
    try await waitUntil { !state.pendingPermissionRequests.isEmpty }

    let pending = try #require(state.pendingPermissionRequests.first)
    state.cancelPermissionRequest(pending.id)

    let response = try await responseTask.value
    #expect(response.outcome == .cancelled)
    #expect(state.pendingPermissionRequests.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func connectionDropWhilePendingClearsStateCleanly() async throws {
    let model = SwiftUIACPClient()
    model.connectionState = .connected

    let responseTask = Task { try await model.requestPermission(permissionRequest()) }
    let state = model.session(for: testSession)
    try await waitUntil { !state.pendingPermissionRequests.isEmpty }

    model.connectionState = .disconnected

    let response = try await responseTask.value
    #expect(response.outcome == .cancelled)
    #expect(state.pendingPermissionRequests.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func twoOverlappingRequestsStayPendingTogetherAndResolveIndependently() async throws {
    let model = SwiftUIACPClient()
    let first = permissionRequest(title: "First?")
    let second = permissionRequest(title: "Second?")

    let firstTask = Task { try await model.requestPermission(first) }
    let state = model.session(for: testSession)
    try await waitUntil { state.pendingPermissionRequests.count == 1 }
    let secondTask = Task { try await model.requestPermission(second) }
    try await waitUntil { state.pendingPermissionRequests.count == 2 }

    // The documented policy: more than one outstanding request is
    // supported, and the list keeps arrival order.
    #expect(state.pendingPermissionRequests.map(\.request.title) == ["First?", "Second?"])

    // An answer lands on the request it names, in any order.
    let secondID = state.pendingPermissionRequests[1].id
    state.answerPermissionRequest(secondID, with: allowOption.optionId)
    let secondResponse = try await secondTask.value
    #expect(secondResponse.outcome == .selected(SelectedPermissionOutcome(optionId: allowOption.optionId)))
    #expect(state.pendingPermissionRequests.map(\.request.title) == ["First?"])

    let firstID = try #require(state.pendingPermissionRequests.first).id
    state.answerPermissionRequest(firstID, with: rejectOption.optionId)
    let firstResponse = try await firstTask.value
    #expect(firstResponse.outcome == .selected(SelectedPermissionOutcome(optionId: rejectOption.optionId)))
    #expect(state.pendingPermissionRequests.isEmpty)
}

@Test
func advertisedCapabilitiesMatchTheImplementedMethods() {
    // ACP stable v2 gates elicitation behind the `elicitation` capability
    // field. This client implements both elicitation modes, so it
    // advertises form and url support, and nothing more.
    let expected = ClientCapabilities(
        elicitation: ElicitationCapabilities(
            form: ElicitationFormCapabilities(),
            url: ElicitationUrlCapabilities()
        )
    )
    #expect(ACPClient.advertisedCapabilities == expected)
}

/// A stub agent that asks for permission during its one prompt turn.
///
/// After the client answers, the stub reports the outcome back as an
/// agent message, so the test can read the outcome from the observable
/// session state.
private final class PermissionStubAgent: Agent {
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
            info: Implementation(name: "permission-stub-agent", version: "1.0.0"),
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
        let response = try await connection.requestPermission(permissionRequest())
        let outcomeText =
            switch response.outcome {
            case .selected(let selected): selected.optionId.rawValue
            case .cancelled: "cancelled"
            case .unknown: "unknown"
            }
        try await connection.sessionUpdate(
            UpdateSessionNotification(
                sessionId: testSession,
                update: .agentMessage(
                    AgentMessage(
                        messageId: MessageId(rawValue: "outcome-1"),
                        content: .value([textBlock(outcomeText)])
                    )
                )
            )
        )
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aStubAgentsPermissionRequestRoundTripsOverTheWire() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let model = SwiftUIACPClient()
    let connection = await ClientSideConnection(stream: clientEnd) { _ in model }
    let agentConnection = await AgentSideConnection(stream: agentEnd) { agentSide in
        PermissionStubAgent(connection: agentSide)
    }

    async let promptResult = connection.prompt(
        PromptRequest(prompt: [textBlock("go")], sessionId: testSession)
    )

    // The agent's request appears as pending state on the session.
    let state = model.session(for: testSession)
    try await waitUntil { !state.pendingPermissionRequests.isEmpty }
    let pending = try #require(state.pendingPermissionRequests.first)
    #expect(pending.request.options == [allowOption, rejectOption])

    // The answer resolves the agent's in-flight request with the
    // selected option, and the agent reports that option back.
    state.answerPermissionRequest(pending.id, with: allowOption.optionId)
    _ = try await promptResult

    #expect(state.messageContent(for: MessageId(rawValue: "outcome-1")) == [textBlock(allowOption.optionId.rawValue)])
    #expect(state.pendingPermissionRequests.isEmpty)

    await connection.close()
    withExtendedLifetime(agentConnection) {}
}
