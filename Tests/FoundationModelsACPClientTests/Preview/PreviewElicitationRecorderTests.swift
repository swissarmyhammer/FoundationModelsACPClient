import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the elicitation answers that `PreviewSessionRequestSender`
// records. The public preview factory makes no pending elicitation, so these
// tests start one through the internal call of the agent's request.

/// Starts one session-scoped form elicitation on a model. The task starts on
/// the main actor at once, so the elicitation is pending when the call
/// returns.
///
/// - Parameter model: The model that holds the elicitation.
/// - Returns: The task of the agent's call.
@MainActor
private func startElicitation(on model: SessionModel) -> Task<CreateElicitationResponse, Never> {
    let request = ElicitationFixtures.formRequest(
        scope: .session(ElicitationSessionScope(sessionId: model.sessionId))
    )
    return Task.immediate { @MainActor in
        await model.awaitElicitation(request)
    }
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
