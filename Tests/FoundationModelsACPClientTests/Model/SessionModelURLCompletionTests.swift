import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of `SessionModel.awaitingURLCompletions`: an accepted url-mode
// elicitation waits there for the `elicitation/complete` of the agent. The
// completion, `stopWaiting(_:)`, `cancel(meta:)`, `cancelAllPending()` and
// the close remove it, and none of them sends a message to the agent.

/// The URL completion tests of the session model, in one suite so that
/// `swift test --filter SessionModelURLCompletionTests` selects them.
@MainActor
@Suite
struct SessionModelURLCompletionTests {
    /// The fake sender of the model under test.
    private let sender = FakeSessionRequestSender()

    /// Makes the model under test.
    private func makeModel() -> SessionModel {
        SessionModel(sessionId: testSession, requestSender: sender)
    }

    /// Starts one session-scoped elicitation and waits until it is pending.
    ///
    /// - Parameters:
    ///   - model: The model that holds the elicitation.
    ///   - request: The request to start.
    /// - Returns: The task of the agent's call.
    private func startElicitation(
        on model: SessionModel,
        _ request: CreateElicitationRequest = ElicitationFixtures.urlRequest(scope: .session(ElicitationFixtures.sessionScope))
    ) async throws -> Task<CreateElicitationResponse, Never> {
        let count = model.pendingElicitations.count
        let task = Task { await model.awaitElicitation(request) }
        try await waitUntil { model.pendingElicitations.count == count + 1 }
        return task
    }

    /// Starts one url-mode elicitation, accepts it, and waits for the answer
    /// of the agent's call.
    ///
    /// - Parameter model: The model that holds the elicitation.
    /// - Returns: The accepted elicitation.
    private func acceptURLElicitation(on model: SessionModel) async throws -> PendingElicitation {
        let task = try await startElicitation(on: model)
        let pending = try #require(model.pendingElicitations.first)
        model.acceptElicitation(pending.id)
        #expect(await task.value == ElicitationResponseWire.acceptResponse(content: nil))
        return pending
    }

    // MARK: - Accept

    @Test func acceptingAUrlElicitationMovesItToTheAwaitingListWithTheSameId() async throws {
        let model = makeModel()

        let pending = try await acceptURLElicitation(on: model)

        #expect(model.pendingElicitations.isEmpty)
        #expect(model.awaitingURLCompletions == [pending])
        #expect(model.awaitingURLCompletions.first?.id == pending.id)
    }

    @Test func acceptingAFormElicitationDoesNotWaitForACompletion() async throws {
        let model = makeModel()
        let task = try await startElicitation(
            on: model,
            ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))
        )

        model.acceptElicitation(try #require(model.pendingElicitations.first).id, content: .object(["name": .string("orion")]))

        _ = await task.value
        #expect(model.awaitingURLCompletions.isEmpty)
    }

    @Test func declineAndCancelOfAUrlElicitationDoNotWaitForACompletion() async throws {
        let model = makeModel()
        let declined = try await startElicitation(on: model)
        model.declineElicitation(try #require(model.pendingElicitations.first).id)
        _ = await declined.value
        let cancelled = try await startElicitation(on: model)

        model.cancelElicitation(try #require(model.pendingElicitations.first).id)

        _ = await cancelled.value
        #expect(model.awaitingURLCompletions.isEmpty)
    }

    @Test func anAcceptFiresTheObservationOfTheAwaitingList() async throws {
        let model = makeModel()
        let task = try await startElicitation(on: model)
        let pending = try #require(model.pendingElicitations.first)

        let fires = observationFires(reading: { _ = model.awaitingURLCompletions }) {
            model.acceptElicitation(pending.id)
        }

        #expect(fires)
        _ = await task.value
    }

    // MARK: - Removal

    @Test func theElicitationCompleteRemovesTheAwaitingItem() async throws {
        let model = makeModel()
        _ = try await acceptURLElicitation(on: model)

        let matched = model.completeElicitation(elicitationId: ElicitationFixtures.urlID)

        #expect(matched)
        #expect(model.awaitingURLCompletions.isEmpty)
    }

    @Test func aCompleteOfAnotherIdKeepsTheAwaitingItem() async throws {
        let model = makeModel()
        let pending = try await acceptURLElicitation(on: model)

        let matched = model.completeElicitation(elicitationId: ElicitationId(rawValue: "other"))

        #expect(!matched)
        #expect(model.awaitingURLCompletions == [pending])
    }

    @Test func stopWaitingRemovesTheItemAndAnUnknownIdChangesNothing() async throws {
        let model = makeModel()
        let pending = try await acceptURLElicitation(on: model)

        model.stopWaiting(UUID())
        #expect(model.awaitingURLCompletions == [pending])

        model.stopWaiting(pending.id)
        #expect(model.awaitingURLCompletions.isEmpty)
        #expect(sender.promptRequests.isEmpty)
        #expect(sender.cancelNotifications.isEmpty)
    }

    @Test func aCancelOfTheWorkRemovesEachAwaitingItem() async throws {
        let model = makeModel()
        _ = try await acceptURLElicitation(on: model)

        try await model.cancel()

        #expect(model.awaitingURLCompletions.isEmpty)
        #expect(sender.cancelNotifications.count == 1)
    }

    @Test func cancelAllPendingRemovesEachAwaitingItem() async throws {
        let model = makeModel()
        _ = try await acceptURLElicitation(on: model)

        model.cancelAllPending()

        #expect(model.awaitingURLCompletions.isEmpty)
    }

    @Test func theCloseRemovesEachAwaitingItem() async throws {
        let model = makeModel()
        _ = try await acceptURLElicitation(on: model)

        model.markClosed()

        #expect(model.awaitingURLCompletions.isEmpty)
    }
}
