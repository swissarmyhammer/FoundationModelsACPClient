import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the front of the pending requests of `SessionModel`: the front
// is the oldest pending request, unless the user brought another request to
// the front. The front is a pointer, so the order of `pendingRequests` does
// not change. The pointer becomes `nil` when its request resolves and when
// the session closes.

/// The tool call that the link tests name.
private let frontToolCallId = ToolCallId(rawValue: "tool-front")

/// The front tests, in one suite so that `swift test --filter
/// SessionModelFrontTests` selects them.
@MainActor
@Suite
struct SessionModelFrontTests {
    /// Starts one session-scoped form elicitation and waits until it is
    /// pending.
    ///
    /// - Parameters:
    ///   - model: The model that holds the elicitation.
    ///   - toolCallId: The tool call that the elicitation names, or `nil`.
    /// - Returns: The task of the agent's call.
    private func startElicitation(
        on model: SessionModel,
        toolCallId: ToolCallId? = nil
    ) async throws -> Task<CreateElicitationResponse, Never> {
        let request = ElicitationFixtures.formRequest(
            scope: .session(ElicitationSessionScope(sessionId: testSession, toolCallId: toolCallId))
        )
        let count = model.pendingElicitations.count
        let task = Task { await model.awaitElicitation(request) }
        try await waitUntil { model.pendingElicitations.count == count + 1 }
        return task
    }

    /// Makes a model that holds two elicitations and a permission request, in
    /// the order E1, E2, P1.
    ///
    /// - Returns: The model, and the tasks of the three calls of the agent.
    private func modelWithE1E2P1() async throws -> (SessionModel, [Task<Void, Never>]) {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let first = try await startElicitation(on: model)
        let second = try await startElicitation(on: model)
        let permission = SessionModelFixtures.startPermission(on: model)
        let tasks = [
            Task { _ = await first.value },
            Task { _ = await second.value },
            Task { _ = await permission.value },
        ]
        return (model, tasks)
    }

    /// Answers each pending request, and waits for each call of the agent.
    ///
    /// - Parameters:
    ///   - model: The model that holds the requests.
    ///   - tasks: The tasks of the calls.
    private func finish(_ model: SessionModel, _ tasks: [Task<Void, Never>]) async {
        model.cancelAllPending()
        for task in tasks { await task.value }
    }

    @Test func theFrontIsTheOldestRequestOrNilWhenNothingIsPending() async throws {
        let empty = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        #expect(empty.frontRequest == nil)
        #expect(empty.frontRequestID == nil)

        let (model, tasks) = try await modelWithE1E2P1()

        #expect(model.frontRequestID == nil)
        #expect(model.frontRequest == model.pendingRequests.first)
        await finish(model, tasks)
    }

    @Test func bringingE2ToTheFrontKeepsTheOrderOfPendingRequests() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        let order = model.pendingRequests
        let e2 = order[1]

        model.bringToFront(e2.id)

        #expect(model.frontRequestID == e2.id)
        #expect(model.frontRequest == e2)
        #expect(model.pendingRequests == order)
        await finish(model, tasks)
    }

    @Test func aResolutionOfTheFrontRequestMovesTheFrontBackToTheOldest() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        let e1 = model.pendingRequests[0]
        let e2 = model.pendingRequests[1]
        model.bringToFront(e2.id)

        model.declineElicitation(e2.id)

        #expect(model.frontRequestID == nil)
        #expect(model.frontRequest == e1)
        await finish(model, tasks)
    }

    @Test func aResolutionOfAnotherRequestKeepsTheFront() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        let e1 = model.pendingRequests[0]
        let e2 = model.pendingRequests[1]
        model.bringToFront(e2.id)

        model.declineElicitation(e1.id)

        #expect(model.frontRequestID == e2.id)
        #expect(model.frontRequest == e2)
        await finish(model, tasks)
    }

    @Test func anUnknownIdChangesNothing() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        let e2 = model.pendingRequests[1]
        model.bringToFront(e2.id)

        model.bringToFront(UUID())

        #expect(model.frontRequestID == e2.id)
        #expect(model.frontRequest == e2)
        await finish(model, tasks)
    }

    @Test func theCloseClearsTheFront() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        model.bringToFront(model.pendingRequests[1].id)

        model.markClosed()

        #expect(model.frontRequestID == nil)
        #expect(model.frontRequest == nil)
        for task in tasks { await task.value }
    }

    @Test func bringingAToolCallToTheFrontSelectsItsOldestLinkedElicitation() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        model.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: frontToolCallId, title: .value("Deploy"))))
        let entry = try #require(model.transcript.first?.toolCall)
        let unlinked = try await startElicitation(on: model)
        let firstLinked = try await startElicitation(on: model, toolCallId: frontToolCallId)
        let secondLinked = try await startElicitation(on: model, toolCallId: frontToolCallId)
        let oldestLinked = try #require(model.pendingElicitations.first { $0.toolCallId == frontToolCallId })

        #expect(model.bringToFront(toolCall: entry))

        #expect(model.frontRequestID == oldestLinked.id)
        #expect(model.frontRequest == .elicitation(oldestLinked))
        model.cancelAllPending()
        _ = await unlinked.value
        _ = await firstLinked.value
        _ = await secondLinked.value
    }

    @Test func aToolCallWithNoLinkedElicitationChangesNothing() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        model.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: frontToolCallId, title: .value("Deploy"))))
        let entry = try #require(model.transcript.first?.toolCall)

        #expect(!model.bringToFront(toolCall: entry))

        #expect(model.frontRequestID == nil)
        await finish(model, tasks)
    }

    @Test func bringingARequestToTheFrontFiresTheObservationOfTheFront() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        let e2 = model.pendingRequests[1]

        let fires = observationFires(reading: { _ = model.frontRequest }) {
            model.bringToFront(e2.id)
        }

        #expect(fires)
        await finish(model, tasks)
    }
}
