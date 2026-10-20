import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the elicitation answers that `PreviewSessionRequestSender`
// records, and of the response that the agent's call gets. The task of the
// agent's call is internal, so these tests start the elicitation through the
// internal `SessionModel.startElicitation(for:)` that the preview factory
// also uses.

/// Starts one session-scoped form elicitation on a model. The task starts on
/// the main actor at once, so the elicitation is pending when the call
/// returns.
///
/// - Parameter model: The model that holds the elicitation.
/// - Returns: The task of the agent's call.
@MainActor
private func startElicitation(on model: SessionModel) -> Task<CreateElicitationResponse, Never> {
    model.startElicitation(
        for: ElicitationFixtures.formRequest(scope: .session(ElicitationSessionScope(sessionId: model.sessionId)))
    )
}

@MainActor
struct PreviewElicitationRecorderTests {
    @Test func aDeclinedElicitationIsRecordedWithTheIdOfThePendingElicitation() async throws {
        let sender = PreviewSessionRequestSender()
        let model = SessionModel.preview(requestSender: sender)
        let call = startElicitation(on: model)
        let pending = try #require(model.pendingElicitations.first)

        model.declineElicitation(pending.id)

        let declined: CreateElicitationResponse = .object(["action": .string("decline")])
        #expect(sender.sent == [.elicitationResponse(id: pending.id, response: declined)])
        #expect(await call.value == declined)
    }

    @Test func anAcceptedElicitationIsRecordedWithItsContent() async throws {
        let sender = PreviewSessionRequestSender()
        let model = SessionModel.preview(requestSender: sender)
        let call = startElicitation(on: model)
        let pending = try #require(model.pendingElicitations.first)
        let content: JSONValue = .object(["name": .string("orion")])

        model.acceptElicitation(pending.id, content: content)

        let accepted: CreateElicitationResponse = .object(["action": .string("accept"), "content": content])
        #expect(sender.sent == [.elicitationResponse(id: pending.id, response: accepted)])
        #expect(await call.value == accepted)
    }
}
