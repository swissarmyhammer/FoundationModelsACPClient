import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the pending requests of `SessionModel`: permission requests and
// session-scoped elicitations become observable pending state on the model. A
// resolution from the UI, a cancellation of the agent's call, and
// `cancelAllPending()` each remove the item and resume its continuation one
// time. A cancel of the work answers each permission request and each
// elicitation before the notification goes out. An elicitation that names a
// tool call links to the entry of that tool call while it is pending.
//
// The wire round trips and the capability test of `PermissionRequestTests` and
// `ElicitationTests` test the `Client` conformance, which the model does not
// have; the routing task of the model client ports them.

/// The option id of the "allow" option of each test permission request.
private let allowOptionId = SessionModelFixtures.allowOption.optionId

/// The option id of the "reject" option of each test permission request.
private let rejectOptionId = SessionModelFixtures.rejectOption.optionId

/// The tool call that the link tests name.
private let linkedToolCallId = ToolCallId(rawValue: "tool-1")

/// The form values that the accept tests give: one "name" string, which
/// matches the requested schema of the fixtures.
private let nameValues: JSONValue = .object(["name": .string("orion")])

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
@Suite
struct SessionModelPendingTests {
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
        let request = SessionModelFixtures.permissionRequest()
        let task = SessionModelFixtures.startPermission(on: model, request)

        // The pending state carries the whole request, so the UI can show the
        // options and the subject context.
        let pending = try #require(model.pendingPermissions.first)
        #expect(pending.request == request)

        await model.selectPermission(pending.id, option: rejectOptionId)

        #expect(model.pendingPermissions.isEmpty)
        let response = await task.value
        #expect(response.outcome == .selected(SelectedPermissionOutcome(optionId: rejectOptionId)))
    }

    @Test func cancellingTheAgentCallAnswersCancelledAndClearsThePermission() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = SessionModelFixtures.startPermission(on: model)

        // Task cancellation is how the connection delivers the agent's
        // withdrawal. The await returns only when the continuation resumed, so
        // a leaked continuation makes the test wait for ever.
        task.cancel()

        let response = await task.value
        #expect(response.outcome == .cancelled)
        #expect(model.pendingPermissions.isEmpty)
    }

    @Test func cancellingFromTheUIAnswersCancelledAndClearsThePermission() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = SessionModelFixtures.startPermission(on: model)

        let pending = try #require(model.pendingPermissions.first)
        await model.cancelPermission(pending.id)

        #expect(model.pendingPermissions.isEmpty)
        let response = await task.value
        #expect(response.outcome == .cancelled)
    }

    @Test func aSecondResolutionOfOnePermissionChangesNothing() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = SessionModelFixtures.startPermission(on: model)
        let pending = try #require(model.pendingPermissions.first)

        await model.selectPermission(pending.id, option: allowOptionId)
        // A second resume of the continuation traps, so these two calls prove
        // that a resolved request resumes one time only.
        await model.selectPermission(pending.id, option: rejectOptionId)
        await model.cancelPermission(pending.id)

        let response = await task.value
        #expect(response.outcome == .selected(SelectedPermissionOutcome(optionId: allowOptionId)))
    }

    @Test func twoOverlappingPermissionsResolveIndependently() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let firstTask = SessionModelFixtures.startPermission(on: model, SessionModelFixtures.permissionRequest(title: "First?"))
        let secondTask = SessionModelFixtures.startPermission(on: model, SessionModelFixtures.permissionRequest(title: "Second?"))

        // More than one outstanding request is supported, in arrival order.
        #expect(model.pendingPermissions.map(\.request.title) == ["First?", "Second?"])

        await model.selectPermission(model.pendingPermissions[1].id, option: allowOptionId)
        let secondResponse = await secondTask.value
        #expect(secondResponse.outcome == .selected(SelectedPermissionOutcome(optionId: allowOptionId)))
        #expect(model.pendingPermissions.map(\.request.title) == ["First?"])

        let first = try #require(model.pendingPermissions.first)
        await model.selectPermission(first.id, option: rejectOptionId)
        let firstResponse = await firstTask.value
        #expect(firstResponse.outcome == .selected(SelectedPermissionOutcome(optionId: rejectOptionId)))
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
        let permissionTask = SessionModelFixtures.startPermission(on: model)
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

    // MARK: - One list in arrival order

    /// Starts a permission, an elicitation, and a second permission, in that
    /// order.
    ///
    /// - Parameter model: The model that holds the requests.
    /// - Returns: The tasks of the three calls of the agent.
    private func startPermissionElicitationPermission(
        on model: SessionModel
    ) async throws -> [Task<Void, Never>] {
        let first = SessionModelFixtures.startPermission(on: model, SessionModelFixtures.permissionRequest(title: "P1"))
        let elicitation = try await startElicitation(on: model)
        let second = SessionModelFixtures.startPermission(on: model, SessionModelFixtures.permissionRequest(title: "P2"))
        return [
            Task { _ = await first.value },
            Task { _ = await elicitation.value },
            Task { _ = await second.value },
        ]
    }

    @Test func pendingRequestsGivesBothKindsInArrivalOrder() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let tasks = try await startPermissionElicitationPermission(on: model)
        let p1 = try #require(model.pendingPermissions.first)
        let p2 = try #require(model.pendingPermissions.last)
        let e1 = try #require(model.pendingElicitations.first)

        #expect(model.pendingRequests == [.permission(p1), .elicitation(e1), .permission(p2)])
        #expect(model.pendingRequests.map(\.id) == [p1.id, e1.id, p2.id])

        model.cancelAllPending()
        for task in tasks { await task.value }
    }

    @Test func aResolutionKeepsTheOrderOfTheOtherRequestsAndTheTypedLists() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let tasks = try await startPermissionElicitationPermission(on: model)
        let p1 = try #require(model.pendingPermissions.first)
        let p2 = try #require(model.pendingPermissions.last)
        let e1 = try #require(model.pendingElicitations.first)

        model.declineElicitation(e1.id)

        #expect(model.pendingRequests == [.permission(p1), .permission(p2)])
        #expect(model.pendingPermissions == [p1, p2])
        #expect(model.pendingElicitations.isEmpty)

        await model.cancelPermission(p1.id)

        #expect(model.pendingRequests == [.permission(p2)])
        #expect(model.pendingPermissions == [p2])
        model.cancelAllPending()
        for task in tasks { await task.value }
    }

    @Test func anArrivalAndAResolutionEachFireTheObservationOfPendingRequests() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        var permissionTask: Task<RequestPermissionResponse, Never>?

        let arrivalFires = observationFires(reading: { _ = model.pendingRequests }) {
            permissionTask = SessionModelFixtures.startPermission(on: model)
        }
        #expect(model.pendingRequests.count == 1)
        let resolutionFires = observationFires(reading: { _ = model.pendingRequests }) {
            model.cancelAllPending()
        }

        #expect(arrivalFires)
        #expect(resolutionFires)
        #expect(model.pendingRequests.isEmpty)
        #expect(await permissionTask?.value.outcome == .cancelled)
    }

    // MARK: - Cancel of the work

    @Test func cancelAnswersEachPendingPermissionWithCancelled() async throws {
        let sender = FakeSessionRequestSender()
        let model = SessionModel(sessionId: testSession, requestSender: sender)
        let firstTask = SessionModelFixtures.startPermission(on: model, SessionModelFixtures.permissionRequest(title: "First?"))
        let secondTask = SessionModelFixtures.startPermission(on: model, SessionModelFixtures.permissionRequest(title: "Second?"))

        try await model.cancel()

        // The require stops the test before the awaits below, which would
        // suspend for ever when a permission stays pending.
        try #require(model.pendingPermissions.isEmpty)
        let firstResponse = await firstTask.value
        #expect(firstResponse.outcome == .cancelled)
        let secondResponse = await secondTask.value
        #expect(secondResponse.outcome == .cancelled)
        #expect(sender.cancelNotifications.count == 1)
    }

    /// Elicitation-plan task 29: a cancel of the work answers each pending
    /// session elicitation with `cancel` and the reason of the client in
    /// `_meta`, and both pending lists are empty when the notification goes
    /// to the sender. Before task 29, this test asked that the cancel keep
    /// the elicitations; the step owner changed that rule.
    @Test func cancelAnswersEachPendingElicitationWithCancelAndTheClientReason() async throws {
        let sender = FakeSessionRequestSender()
        let model = SessionModel(sessionId: testSession, requestSender: sender)
        model.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: linkedToolCallId, title: .value("Deploy"))))
        let entry = try #require(model.transcript.first?.toolCall)
        let permissionTask = SessionModelFixtures.startPermission(on: model)
        let formTask = try await startElicitation(on: model, sessionFormRequest(toolCallId: linkedToolCallId))
        let urlTask = try await startElicitation(
            on: model,
            ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
        )
        let pendingAtCancel = ThreadSafeBuffer<Int>()
        sender.observeCancels { _ in
            pendingAtCancel.append(model.pendingPermissions.count + model.pendingElicitations.count)
        }

        try await model.cancel()

        #expect(pendingAtCancel.elements == [0])
        #expect(entry.linkedElicitationIDs.isEmpty)
        let cancelled = ElicitationResponseWire.cancelResponse(reason: ACPClient.clientCancelledReason)
        #expect(await formTask.value == cancelled)
        #expect(await urlTask.value == cancelled)
        #expect(await permissionTask.value.outcome == .cancelled)
        #expect(sender.cancelNotifications.count == 1)
    }

    @Test func theReasonOfAClientCancelIsInTheMetaOfTheAnswer() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let task = try await startElicitation(on: model)

        try await model.cancel()

        let answer = await task.value
        #expect(
            answer == .object([
                "action": .string("cancel"),
                "_meta": .object(["reason": .string("the client cancelled the work")]),
            ])
        )
    }

    @Test func aCancelWithNoPendingItemSendsOnlyTheNotification() async throws {
        let sender = FakeSessionRequestSender()
        let model = SessionModel(sessionId: testSession, requestSender: sender)

        try await model.cancel()

        #expect(sender.cancelNotifications.map(\.sessionId) == [testSession])
        #expect(model.pendingPermissions.isEmpty)
        #expect(model.pendingElicitations.isEmpty)
    }

    @Test func aCancelThatFailsToSendStillCancelsThePermissionsAndTheElicitations() async throws {
        let sender = FakeSessionRequestSender()
        sender.failCancels(with: ConnectionError.closed)
        let model = SessionModel(sessionId: testSession, requestSender: sender)
        let task = SessionModelFixtures.startPermission(on: model)
        let elicitationTask = try await startElicitation(on: model)

        await #expect(throws: ConnectionError.closed) {
            try await model.cancel()
        }

        // The user asked to stop the work, so no request waits for an agent
        // that the notification did not reach.
        try #require(model.pendingPermissions.isEmpty)
        try #require(model.pendingElicitations.isEmpty)
        let response = await task.value
        #expect(response.outcome == .cancelled)
        #expect(await elicitationTask.value == ElicitationResponseWire.cancelResponse(reason: ACPClient.clientCancelledReason))
    }
}
