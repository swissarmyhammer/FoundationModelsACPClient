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
    /// pending. The end of the agent's call is the failure event: after it,
    /// the elicitation never becomes pending.
    ///
    /// - Parameters:
    ///   - model: The model that holds the elicitation.
    ///   - toolCallId: The tool call that the elicitation names, or `nil`.
    /// - Returns: The task of the agent's call.
    /// - Throws: ``WaitEndedOnFailure`` when the call ended first.
    private func startElicitation(
        on model: SessionModel,
        toolCallId: ToolCallId? = nil
    ) async throws -> Task<CreateElicitationResponse, Never> {
        let request = ElicitationFixtures.formRequest(
            scope: .session(ElicitationSessionScope(sessionId: testSession, toolCallId: toolCallId))
        )
        let count = model.pendingElicitations.count
        let task = Task { await model.awaitElicitation(request) }
        let taskEnd = TaskEnd(of: task)
        try await waitUntil { model.pendingElicitations.count == count + 1 } orFailWhen: { taskEnd.hasEnded }
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
    /// A request that is still pending has no answer, so the test fails
    /// before the wait and does not hang.
    ///
    /// - Parameters:
    ///   - model: The model that holds the requests.
    ///   - tasks: The tasks of the calls.
    /// - Throws: The error of `#require` when a request is still pending.
    private func finish(_ model: SessionModel, _ tasks: [Task<Void, Never>]) async throws {
        model.cancelAllPending()
        try #require(model.pendingRequests.isEmpty)
        for task in tasks { await task.value }
    }

    @Test func theFrontIsTheOldestRequestOrNilWhenNothingIsPending() async throws {
        let empty = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        #expect(empty.frontRequest == nil)
        #expect(empty.frontRequestID == nil)

        let (model, tasks) = try await modelWithE1E2P1()

        #expect(model.frontRequestID == nil)
        #expect(model.frontRequest == model.pendingRequests.first)
        try await finish(model, tasks)
    }

    @Test func bringingE2ToTheFrontKeepsTheOrderOfPendingRequests() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        let order = model.pendingRequests
        let e2 = order[1]

        model.bringToFront(e2.id)

        #expect(model.frontRequestID == e2.id)
        #expect(model.frontRequest == e2)
        #expect(model.pendingRequests == order)
        try await finish(model, tasks)
    }

    @Test func aResolutionOfTheFrontRequestMovesTheFrontBackToTheOldest() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        let e1 = model.pendingRequests[0]
        let e2 = model.pendingRequests[1]
        model.bringToFront(e2.id)

        model.declineElicitation(e2.id)

        #expect(model.frontRequestID == nil)
        #expect(model.frontRequest == e1)
        try await finish(model, tasks)
    }

    @Test func aResolutionOfAnotherRequestKeepsTheFront() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        let e1 = model.pendingRequests[0]
        let e2 = model.pendingRequests[1]
        model.bringToFront(e2.id)

        model.declineElicitation(e1.id)

        #expect(model.frontRequestID == e2.id)
        #expect(model.frontRequest == e2)
        try await finish(model, tasks)
    }

    @Test func anUnknownIdChangesNothing() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        let e2 = model.pendingRequests[1]
        model.bringToFront(e2.id)

        model.bringToFront(UUID())

        #expect(model.frontRequestID == e2.id)
        #expect(model.frontRequest == e2)
        try await finish(model, tasks)
    }

    @Test func theCloseClearsTheFront() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        model.bringToFront(model.pendingRequests[1].id)

        model.markClosed()

        #expect(model.frontRequestID == nil)
        #expect(model.frontRequest == nil)
        // A request that is still pending is not cancelled, so the test
        // fails here and does not wait for the calls.
        try #require(model.pendingRequests.isEmpty)
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
        // An elicitation that is still pending has no answer, so the test
        // fails here and does not wait for the calls.
        try #require(model.pendingElicitations.isEmpty)
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
        try await finish(model, tasks)
    }

    @Test func bringingARequestToTheFrontFiresTheObservationOfTheFront() async throws {
        let (model, tasks) = try await modelWithE1E2P1()
        let e2 = model.pendingRequests[1]

        let fires = observationFires(reading: { _ = model.frontRequest }) {
            model.bringToFront(e2.id)
        }

        #expect(fires)
        try await finish(model, tasks)
    }
}
