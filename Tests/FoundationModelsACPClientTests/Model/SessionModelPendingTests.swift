import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the pending requests of `SessionModel`: permission requests and
// session-scoped elicitations become observable pending state on the model. A
// resolution from the UI, a cancellation of the agent's call, and
// `cancelAllPending()` each remove the item and resume its continuation one
// time. An elicitation that names a tool call links to the entry of that tool
// call while it is pending.
//
// The wire round trips and the capability test of `PermissionRequestTests` and
// `ElicitationTests` test the `Client` conformance, which the model does not
// have; the routing task of the model client ports them.

/// The "allow" option that each test permission request offers.
private let allowOption = PermissionOption(
    kind: .allowOnce,
    name: "Allow",
    optionId: PermissionOptionId(rawValue: "allow-once")
)

/// The "reject" option that each test permission request offers.
private let rejectOption = PermissionOption(
    kind: .rejectOnce,
    name: "Reject",
    optionId: PermissionOptionId(rawValue: "reject-once")
)

/// The tool call that the link tests name.
private let linkedToolCallId = ToolCallId(rawValue: "tool-1")

/// The form values that the accept tests give: one "name" string, which
/// matches the requested schema of the fixtures.
private let nameValues: JSONValue = .object(["name": .string("orion")])

/// Makes a permission request for the test session.
///
/// - Parameter title: The title of the permission prompt.
/// - Returns: The request, with the two test options.
private func permissionRequest(title: String = "Run the tool?") -> RequestPermissionRequest {
    RequestPermissionRequest(options: [allowOption, rejectOption], sessionId: testSession, title: title)
}

/// Makes a session-scoped form elicitation for the test session.
///
/// - Parameter toolCallId: The tool call the elicitation names, or `nil`.
/// - Returns: The request.
private func sessionFormRequest(toolCallId: ToolCallId? = nil) -> CreateElicitationRequest {
    ElicitationFixtures.formRequest(
        scope: .session(ElicitationSessionScope(sessionId: testSession, toolCallId: toolCallId))
    )
}

/// The pending-request tests, in one suite so that `swift test --filter
/// SessionModelPendingTests` selects them.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionModelPendingTests {
    /// Starts one permission request and waits until it is pending.
    ///
    /// - Parameters:
    ///   - model: The model that holds the request.
    ///   - request: The request to start.
    /// - Returns: The task of the agent's call.
    private func startPermission(
        on model: SessionModel,
        _ request: RequestPermissionRequest = permissionRequest()
    ) async throws -> Task<RequestPermissionResponse, Never> {
        let count = model.pendingPermissions.count
        let task = Task { await model.awaitPermissionDecision(for: request) }
        try await waitUntil { model.pendingPermissions.count == count + 1 }
        return task
    }

    /// Starts one elicitation and waits until it is pending.
    ///
    /// - Parameters:
    ///   - model: The model that holds the elicitation.
    ///   - request: The request to start.
    /// - Returns: The task of the agent's call.
    private func startElicitation(
        on model: SessionModel,
        _ request: CreateElicitationRequest = sessionFormRequest()
    ) async throws -> Task<CreateElicitationResponse, Never> {
        let count = model.pendingElicitations.count
        let task = Task { await model.awaitElicitation(request) }
        try await waitUntil { model.pendingElicitations.count == count + 1 }
        return task
    }

    /// Makes a model that holds one tool-call entry for the linked tool call.
    ///
    /// - Returns: The model and the entry.
    private func modelWithToolCall() throws -> (SessionModel, ToolCallEntry) {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        model.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: linkedToolCallId, title: .value("Deploy"))))
        let entry = try #require(model.transcript.first?.toolCall)
        return (model, entry)
    }

    // MARK: - Permissions

    @Test func selectingAnOptionResolvesThePermissionWithThatOption() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let request = permissionRequest()
        let task = try await startPermission(on: model, request)

        // The pending state carries the whole request, so the UI can show the
        // options and the subject context.
        let pending = try #require(model.pendingPermissions.first)
        #expect(pending.request == request)

        model.selectPermission(pending.id, option: rejectOption.optionId)

        #expect(model.pendingPermissions.isEmpty)
        let response = await task.value
        #expect(response.outcome == .selected(SelectedPermissionOutcome(optionId: rejectOption.optionId)))
    }

    @Test func cancellingTheAgentCallAnswersCancelledAndClearsThePermission() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startPermission(on: model)

        // Task cancellation is how the connection delivers the agent's
        // withdrawal. The await returns only when the continuation resumed, so
        // a leaked continuation makes the test time out.
        task.cancel()

        let response = await task.value
        #expect(response.outcome == .cancelled)
        #expect(model.pendingPermissions.isEmpty)
    }

    @Test func cancellingFromTheUIAnswersCancelledAndClearsThePermission() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startPermission(on: model)

        let pending = try #require(model.pendingPermissions.first)
        model.cancelPermission(pending.id)

        #expect(model.pendingPermissions.isEmpty)
        let response = await task.value
        #expect(response.outcome == .cancelled)
    }

    @Test func aSecondResolutionOfOnePermissionChangesNothing() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startPermission(on: model)
        let pending = try #require(model.pendingPermissions.first)

        model.selectPermission(pending.id, option: allowOption.optionId)
        // A second resume of the continuation traps, so these two calls prove
        // that a resolved request resumes one time only.
        model.selectPermission(pending.id, option: rejectOption.optionId)
        model.cancelPermission(pending.id)

        let response = await task.value
        #expect(response.outcome == .selected(SelectedPermissionOutcome(optionId: allowOption.optionId)))
    }

    @Test func twoOverlappingPermissionsResolveIndependently() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let firstTask = try await startPermission(on: model, permissionRequest(title: "First?"))
        let secondTask = try await startPermission(on: model, permissionRequest(title: "Second?"))

        // More than one outstanding request is supported, in arrival order.
        #expect(model.pendingPermissions.map(\.request.title) == ["First?", "Second?"])

        model.selectPermission(model.pendingPermissions[1].id, option: allowOption.optionId)
        let secondResponse = await secondTask.value
        #expect(secondResponse.outcome == .selected(SelectedPermissionOutcome(optionId: allowOption.optionId)))
        #expect(model.pendingPermissions.map(\.request.title) == ["First?"])

        model.selectPermission(try #require(model.pendingPermissions.first).id, option: rejectOption.optionId)
        let firstResponse = await firstTask.value
        #expect(firstResponse.outcome == .selected(SelectedPermissionOutcome(optionId: rejectOption.optionId)))
        #expect(model.pendingPermissions.isEmpty)
    }

    // MARK: - Elicitations

    @Test func acceptingAFormElicitationResolvesWithAcceptAndTheValues() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let request = sessionFormRequest()
        let task = try await startElicitation(on: model, request)

        let pending = try #require(model.pendingElicitations.first)
        #expect(pending.request == request)
        #expect(pending.sessionId == testSession)

        model.acceptElicitation(pending.id, content: nameValues)

        #expect(model.pendingElicitations.isEmpty)
        let response = await task.value
        #expect(response == .object(["action": .string("accept"), "content": nameValues]))
    }

    @Test func decliningAnElicitationResolvesWithDecline() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startElicitation(on: model)

        model.declineElicitation(try #require(model.pendingElicitations.first).id)

        #expect(model.pendingElicitations.isEmpty)
        let response = await task.value
        #expect(response == .object(["action": .string("decline")]))
    }

    @Test func cancellingAnElicitationFromTheUIResolvesWithCancel() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startElicitation(on: model)

        model.cancelElicitation(try #require(model.pendingElicitations.first).id)

        #expect(model.pendingElicitations.isEmpty)
        let response = await task.value
        #expect(response == .object(["action": .string("cancel")]))
    }

    @Test func cancellingTheAgentCallResolvesTheElicitationWithCancel() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startElicitation(on: model)

        task.cancel()

        let response = await task.value
        #expect(response == .object(["action": .string("cancel")]))
        #expect(model.pendingElicitations.isEmpty)
    }

    @Test func aPendingUrlElicitationShowsTheTargetHostForTheConsentGate() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startElicitation(
            on: model,
            ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        )

        // The model never navigates on its own. It shows the URL and the
        // target host, so the UI can get the user's consent first.
        let pending = try #require(model.pendingElicitations.first)
        #expect(pending.elicitationId == ElicitationFixtures.urlID)
        #expect(pending.url == URL(string: ElicitationFixtures.urlString))
        #expect(pending.targetHost == "example.test")

        model.cancelElicitation(pending.id)
        _ = await task.value
    }

    @Test func completingAUrlElicitationResolvesWithAcceptAndNoContent() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startElicitation(
            on: model,
            ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        )

        #expect(model.completeElicitation(elicitationId: ElicitationFixtures.urlID))

        // The URL flow returned its data out of band, so no credentials go
        // back over ACP.
        #expect(model.pendingElicitations.isEmpty)
        let response = await task.value
        #expect(response == .object(["action": .string("accept")]))
    }

    @Test func completingAnUnknownElicitationIdChangesNothing() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startElicitation(
            on: model,
            ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        )

        #expect(!model.completeElicitation(elicitationId: ElicitationId(rawValue: "other")))
        #expect(model.pendingElicitations.count == 1)

        model.cancelElicitation(try #require(model.pendingElicitations.first).id)
        _ = await task.value
    }

    @Test func theRequestIdIsNilForASessionScopeAndSetForARequestScope() {
        let sessionScoped = PendingElicitation(id: UUID(), request: sessionFormRequest())
        let requestScoped = PendingElicitation(
            id: UUID(),
            request: ElicitationFixtures.urlRequest(scope: .request(ElicitationFixtures.requestScope))
        )

        #expect(sessionScoped.requestId == nil)
        #expect(requestScoped.requestId == ElicitationFixtures.requestScope.requestId)
    }

    // MARK: - Tool-call links

    @Test func toolCallLinkWhenToolCallExists() async throws {
        let (model, entry) = try modelWithToolCall()
        let task = try await startElicitation(on: model, sessionFormRequest(toolCallId: linkedToolCallId))

        let pending = try #require(model.pendingElicitations.first)
        #expect(pending.toolCallId == linkedToolCallId)
        #expect(entry.linkedElicitationIDs == [pending.id])

        model.acceptElicitation(pending.id, content: nameValues)

        #expect(entry.linkedElicitationIDs.isEmpty)
        _ = await task.value
    }

    @Test func toolCallLinkWhenElicitationArrivesFirst() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startElicitation(on: model, sessionFormRequest(toolCallId: linkedToolCallId))
        let pending = try #require(model.pendingElicitations.first)

        // The tool call arrives after the elicitation, and its new entry
        // shows the link at once.
        model.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: linkedToolCallId, title: .value("Deploy"))))
        let entry = try #require(model.transcript.first?.toolCall)
        #expect(entry.linkedElicitationIDs == [pending.id])

        model.declineElicitation(pending.id)

        #expect(entry.linkedElicitationIDs.isEmpty)
        _ = await task.value
    }

    @Test func aWithdrawnElicitationArrivingFirstLeavesNoLinkForALaterToolCall() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startElicitation(on: model, sessionFormRequest(toolCallId: linkedToolCallId))

        task.cancel()
        _ = await task.value

        model.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: linkedToolCallId, title: .value("Deploy"))))
        let entry = try #require(model.transcript.first?.toolCall)
        #expect(entry.linkedElicitationIDs.isEmpty)
    }

    @Test func cancelAllPendingAnswersEveryItem() async throws {
        let (model, entry) = try modelWithToolCall()
        let permissionTask = try await startPermission(on: model)
        let formTask = try await startElicitation(on: model, sessionFormRequest(toolCallId: linkedToolCallId))
        let urlTask = try await startElicitation(
            on: model,
            ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        )

        model.cancelAllPending()

        #expect(model.pendingPermissions.isEmpty)
        #expect(model.pendingElicitations.isEmpty)
        #expect(entry.linkedElicitationIDs.isEmpty)
        let permissionResponse = await permissionTask.value
        #expect(permissionResponse.outcome == .cancelled)
        let cancel: JSONValue = .object(["action": .string("cancel")])
        let formResponse = await formTask.value
        #expect(formResponse == cancel)
        let urlResponse = await urlTask.value
        #expect(urlResponse == cancel)
    }
}
