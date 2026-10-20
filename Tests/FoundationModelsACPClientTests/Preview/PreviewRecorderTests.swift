import FoundationModelsACP
import FoundationModelsACPClient
import Testing

// The tests of a model that code builds with no wire: `SessionModel.apply(_:)`
// changes it, and `PreviewSessionRequestSender.sent` records what it sends.
// The same recorder reads the answers to the request-scoped elicitations of a
// preview `ConnectionModel`. This file uses only the public API: it has no
// `@testable import`, so it uses the model as a test of a host app uses it.

/// The shared values of the recorder tests.
private enum RecorderFixtures {
    /// The text of the user message that a test prompts with.
    static let promptText = "Fix the failing test."

    /// The content of the prompt of a test.
    static let promptContent: [ContentBlock] = [textBlock(promptText)]

    /// The permission request of a preview session, with the shared "allow"
    /// option.
    static let permissionRequest = RequestPermissionRequest(
        options: [SessionModelFixtures.allowOption],
        sessionId: SessionModel.previewSessionId,
        title: "Run swift test?"
    )

    /// A form elicitation of the preview session.
    static let sessionElicitation = ElicitationFixtures.formRequest(
        scope: .session(ElicitationSessionScope(sessionId: SessionModel.previewSessionId))
    )

    /// A form elicitation that names the shared client request.
    static let requestElicitation = ElicitationFixtures.formRequest(scope: .request(ElicitationFixtures.requestScope))

    /// The answer of a declined elicitation, as the spec's action object.
    static let declinedResponse: CreateElicitationResponse = .object(["action": .string("decline")])
}

@MainActor
extension TranscriptEntry {
    /// The agent-message object, or `nil` for another kind.
    fileprivate var agentMessageEntry: AgentMessageEntry? {
        if case .agentMessage(let entry) = self { entry } else { nil }
    }
}

/// Records that an async call returned. The test reads it on the main actor
/// after it starts the call.
@MainActor
private final class ReturnMark {
    /// Whether the call returned.
    private(set) var hasReturned = false

    /// Records that the call returned.
    func markReturned() {
        hasReturned = true
    }
}

@MainActor
struct PreviewRecorderTests {
    // MARK: - SessionModel.apply

    @Test func twoAppliedChunksFoldAtOnceIntoOneAgentMessage() throws {
        let model = SessionModel.preview()

        model.apply(agentChunk(text: "Hello, "))
        model.apply(agentChunk(text: "world."))

        #expect(model.transcript.count == 1)
        let message = try #require(model.transcript.first?.agentMessageEntry)
        #expect(message.content == [textBlock("Hello, "), textBlock("world.")])
    }

    @Test func anAppliedStateUpdateSetsTheAgentState() {
        let model = SessionModel.preview()

        model.apply(.stateUpdate(.running(RunningStateUpdate())))

        #expect(model.agentState == .running(RunningStateUpdate()))
    }

    // MARK: - The recorder of the sent requests

    @Test func aPromptOfAModelThatCodeBuiltIsRecordedAsTheSessionPromptRequest() async throws {
        let sender = PreviewSessionRequestSender()
        let model = SessionModel.preview(requestSender: sender)
        model.apply(agentChunk(text: "How can I help?"))

        _ = try await model.prompt(RecorderFixtures.promptContent)

        let expected = PromptRequest(prompt: RecorderFixtures.promptContent, sessionId: model.sessionId)
        #expect(sender.sent == [.prompt(expected)])
    }

    @Test func aCancelAndAConfigChangeAreRecordedInSendOrder() async throws {
        let sender = PreviewSessionRequestSender()
        let model = SessionModel.preview(requestSender: sender)
        let change = SetSessionConfigOptionRequest(
            configId: SessionConfigId(rawValue: "mode"),
            sessionId: model.sessionId,
            value: .id(SessionConfigValueId(rawValue: "fast"))
        )

        try await model.cancel()
        try await model.setConfigOption(change)

        #expect(sender.sent == [.cancel(CancelSessionNotification(sessionId: model.sessionId)), .setConfigOption(change)])
    }

    @Test func aNewSenderHasRecordedNothing() {
        #expect(PreviewSessionRequestSender().sent.isEmpty)
    }

    @Test func aSelectedPermissionIsRecordedWithTheIdOfThePendingRequest() async throws {
        let sender = PreviewSessionRequestSender()
        let model = SessionModel.preview(pendingPermissions: [RecorderFixtures.permissionRequest], requestSender: sender)
        let pending = try #require(model.pendingPermissions.first)

        await model.selectPermission(pending.id, option: SessionModelFixtures.allowOption.optionId)

        let selected = RequestPermissionResponse(
            outcome: .selected(SelectedPermissionOutcome(optionId: SessionModelFixtures.allowOption.optionId))
        )
        #expect(sender.sent == [.permissionResponse(id: pending.id, response: selected)])
    }

    @Test func aCancelledPermissionIsRecordedWithTheCancelledOutcome() async throws {
        let sender = PreviewSessionRequestSender()
        let model = SessionModel.preview(pendingPermissions: [RecorderFixtures.permissionRequest], requestSender: sender)
        let pending = try #require(model.pendingPermissions.first)

        await model.cancelPermission(pending.id)

        #expect(sender.sent == [.permissionResponse(id: pending.id, response: RequestPermissionResponse(outcome: .cancelled))])
    }

    @Test func aCancelOfTheWorkRecordsThePermissionAnswerBeforeTheCancel() async throws {
        let sender = PreviewSessionRequestSender()
        let model = SessionModel.preview(pendingPermissions: [RecorderFixtures.permissionRequest], requestSender: sender)
        let pending = try #require(model.pendingPermissions.first)

        try await model.cancel()

        #expect(
            sender.sent == [
                .permissionResponse(id: pending.id, response: RequestPermissionResponse(outcome: .cancelled)),
                .cancel(CancelSessionNotification(sessionId: model.sessionId)),
            ]
        )
    }

    // MARK: - No wait for a write on a preview model

    @Test func selectPermissionOnAPreviewModelReturnsAtOnce() async throws {
        let model = SessionModel.preview(pendingPermissions: [RecorderFixtures.permissionRequest])
        let pending = try #require(model.pendingPermissions.first)
        let mark = ReturnMark()

        let call = Task.immediate { @MainActor in
            await model.selectPermission(pending.id, option: SessionModelFixtures.allowOption.optionId)
            mark.markReturned()
        }

        #expect(mark.hasReturned)
        await call.value
    }

    @Test func cancelPermissionOnAPreviewModelReturnsAtOnce() async throws {
        let model = SessionModel.preview(pendingPermissions: [RecorderFixtures.permissionRequest])
        let pending = try #require(model.pendingPermissions.first)
        let mark = ReturnMark()

        let call = Task.immediate { @MainActor in
            await model.cancelPermission(pending.id)
            mark.markReturned()
        }

        #expect(mark.hasReturned)
        await call.value
    }

    // MARK: - Pending elicitations of a preview model

    @Test func aPreviewElicitationIsPendingAfterThePreviewPermissions() throws {
        let model = SessionModel.preview(
            pendingPermissions: [RecorderFixtures.permissionRequest],
            pendingElicitations: [RecorderFixtures.sessionElicitation]
        )

        let permission = try #require(model.pendingPermissions.first)
        let elicitation = try #require(model.pendingElicitations.first)
        #expect(elicitation.request == RecorderFixtures.sessionElicitation)
        #expect(model.pendingRequests == [.permission(permission), .elicitation(elicitation)])
    }

    @Test func aDeclinedPreviewElicitationIsRecordedWithTheIdOfThePendingElicitation() throws {
        let sender = PreviewSessionRequestSender()
        let model = SessionModel.preview(pendingElicitations: [RecorderFixtures.sessionElicitation], requestSender: sender)
        let pending = try #require(model.pendingElicitations.first)

        model.declineElicitation(pending.id)

        #expect(model.pendingElicitations.isEmpty)
        #expect(sender.sent == [.elicitationResponse(id: pending.id, response: RecorderFixtures.declinedResponse)])
    }

    // MARK: - Pending request-scoped elicitations of a preview connection

    @Test func aPreviewConnectionHoldsEachElicitationAsRequestScoped() throws {
        let connection = ConnectionModel.preview(pendingElicitations: [RecorderFixtures.requestElicitation])

        let pending = try #require(connection.pendingElicitations.first)
        #expect(pending.request == RecorderFixtures.requestElicitation)
        #expect(pending.requestId == ElicitationFixtures.requestScope.requestId)
        #expect(connection.pendingRequests == [.elicitation(pending)])
    }

    @Test func aDeclinedPreviewConnectionElicitationIsRecordedInTheRecorder() throws {
        let recorder = PreviewSessionRequestSender()
        let connection = ConnectionModel.preview(
            pendingElicitations: [RecorderFixtures.requestElicitation],
            recorder: recorder
        )
        let pending = try #require(connection.pendingElicitations.first)

        connection.declineElicitation(pending.id)

        #expect(connection.pendingElicitations.isEmpty)
        #expect(recorder.sent == [.elicitationResponse(id: pending.id, response: RecorderFixtures.declinedResponse)])
    }
}
