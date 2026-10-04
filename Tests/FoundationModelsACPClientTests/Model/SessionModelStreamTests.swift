import Foundation
import FoundationModelsACP
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// The tests of the stream life of `SessionModel`: the attached subscription,
// the missed-updates mark, the replay of a resumed session, the history value,
// and the close.

/// The tool call of the replay fixture.
private let replayedToolCallId = ToolCallId(rawValue: "tool-1")

/// The replay cursor that asks for the full retained history.
private let replayFromStart: ReplayFrom = .start(ReplayFromStart())

/// The replay cursor of a type that this schema revision does not know.
private let replayFromCursor: ReplayFrom = .unknown("cursor", .object([:]))

/// The updates that a replay of the test session gives: a user message, an
/// agent message in two chunks, a tool call, a usage report, and the turn end.
private let replayedUpdates: [SessionUpdate] = [
    userChunk(text: "Hello"),
    agentChunk(text: "Hi "),
    agentChunk(text: "there"),
    toolCallStatus(id: replayedToolCallId.rawValue, .completed),
    .usageUpdate(SessionModelFixtures.usage),
    idleState(stopReason: .endTurn),
]

/// The number of transcript entries that the replay fixture gives: the user
/// message, the agent message, and the tool call.
private let replayedEntryCount = 3

/// The number of the JSON-RPC ID of ``markedRequestId``. The connection
/// gives its requests ascending numbers.
private let markedRequestNumber: Double = 1

/// The number of the JSON-RPC ID of ``runningRequestId``: the number of the
/// request that the connection sends after the request of
/// ``markedRequestNumber``.
private let runningRequestNumber: Double = 2

/// The JSON-RPC ID of the request whose marker a hand-made stream carries.
private let markedRequestId: RequestId = .number(markedRequestNumber)

/// The JSON-RPC ID of a `session/resume` request that started after the
/// request of ``markedRequestId``.
private let runningRequestId: RequestId = .number(runningRequestNumber)

/// Makes the marker of a finished request of the test session.
///
/// - Parameters:
///   - outcome: How the request finished.
///   - method: The wire method of the request.
/// - Returns: The marker, as the connection yields it.
private func requestFinished(
    _ outcome: OutgoingRequestOutcome,
    method: String = ClientRequestSpan.Method.resumeSession
) -> SessionStreamEvent {
    .requestFinished(id: markedRequestId, method: method, outcome: outcome)
}

/// The id of the summary message that a compaction writes into the record.
private let summaryMessageId = MessageId(rawValue: "summary-1")

/// The command that the compacted record announces.
private let compactedRecordCommand = AvailableCommand(description: "Makes a plan", name: "create_plan")

/// The live updates of the first turn, before the compaction.
private let firstTurnUpdates: [SessionUpdate] = [
    userChunk(text: "first question", message: "user-1"),
    agentChunk(text: "first answer", message: "agent-1"),
    idleState(stopReason: .endTurn),
]

/// The live updates of the second turn, after the compaction.
private let secondTurnUpdates: [SessionUpdate] = [
    userChunk(text: "second question", message: "user-2"),
    agentChunk(text: "second answer", message: "agent-2"),
    idleState(stopReason: .endTurn),
]

/// The replay of the record after the compaction: one summary message in
/// place of the first turn, then the whole second turn. The agent message of
/// the second turn replays in two chunks, so a replay that lands two times
/// shows the text two times.
private let compactedRecord: [SessionUpdate] = [
    .agentMessage(AgentMessage(messageId: summaryMessageId, content: .value([textBlock("summary of the first turn")]))),
    .userMessage(UserMessage(messageId: MessageId(rawValue: "user-2"), content: .value([textBlock("second question")]))),
    agentChunk(text: "second ", message: "agent-2"),
    agentChunk(text: "answer", message: "agent-2"),
    toolCallStatus(id: replayedToolCallId.rawValue, .completed),
    .availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [compactedRecordCommand])),
    .sessionInfoUpdate(SessionInfoUpdate(title: .value("Compacted session"))),
    idleState(stopReason: .endTurn),
]

/// Runs one successful replay from the start into a model.
///
/// - Parameters:
///   - updates: The replayed updates, in order.
///   - model: The model that receives the replay.
@MainActor
private func replayFixture(_ updates: [SessionUpdate] = replayedUpdates, into model: SessionModel) {
    model.beginReplay(replayFrom: replayFromStart)
    model.applyEach(updates)
    model.endReplay(succeeded: true)
}

extension SessionModel {
    /// The content of each message entry of the transcript, in order, and
    /// `nil` for an entry that is not a message.
    fileprivate var messageContents: [[ContentBlock]?] {
        transcript.map { $0.userMessage?.content ?? $0.agentMessage?.content ?? $0.thought?.content }
    }
}

/// The stream tests, in one suite so that `swift test --filter
/// SessionModelStreamTests` selects them. A wait for an update that never
/// lands would suspend forever, so the suite has a time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionModelStreamTests {
    // MARK: - Attachment

    @Test func updatesOnTheAttachedSubscriptionLandInOrder() async throws {
        let model = SessionModelFixtures.immediateModel()
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()

        model.attach(subscription)
        continuation.yield(.update(agentChunk(text: "first")))
        continuation.yield(.update(toolCallStatus(id: replayedToolCallId.rawValue, .pending)))
        continuation.yield(.update(idleState(stopReason: .endTurn)))
        try await waitUntil { model.agentState != nil }

        #expect(model.transcript.map(\.id) == [.wire(.agentMessage(MessageId(rawValue: "agent-1"))), .wire(.toolCall(replayedToolCallId))])
        #expect(model.agentState == .idle(IdleStateUpdate(stopReason: .endTurn)))
    }

    @Test func theEndOfTheSubscriptionEndsTheUpdateTap() async {
        let model = SessionModelFixtures.immediateModel()
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
        var tap = model.updateTap().makeAsyncIterator()

        model.attach(subscription)
        continuation.finish()

        #expect(await tap.next() == nil)
    }

    // MARK: - Missed updates

    @Test func aSubscriptionWithMissedUpdatesSetsTheMark() {
        let model = SessionModelFixtures.immediateModel()

        model.attach(SessionModelFixtures.handMadeSubscription(hasMissedUpdates: true).0)

        #expect(model.hasMissedUpdates)
    }

    @Test func aSubscriptionWithNoMissedUpdatesLeavesTheMarkClear() {
        let model = SessionModelFixtures.immediateModel()

        model.attach(SessionModelFixtures.handMadeSubscription().0)

        #expect(!model.hasMissedUpdates)
    }

    @Test func aSuccessfulReplayFromTheStartClearsTheMark() {
        let model = SessionModelFixtures.immediateModel()
        model.attach(SessionModelFixtures.handMadeSubscription(hasMissedUpdates: true).0)

        model.beginReplay(replayFrom: replayFromStart)
        model.endReplay(succeeded: true)

        #expect(!model.hasMissedUpdates)
    }

    @Test func aFailedReplayFromTheStartKeepsTheMark() {
        let model = SessionModelFixtures.immediateModel()
        model.attach(SessionModelFixtures.handMadeSubscription(hasMissedUpdates: true).0)

        model.beginReplay(replayFrom: replayFromStart)
        model.endReplay(succeeded: false)

        #expect(model.hasMissedUpdates)
    }

    @Test func aSuccessfulReplayFromACursorKeepsTheMark() {
        let model = SessionModelFixtures.immediateModel()
        model.attach(SessionModelFixtures.handMadeSubscription(hasMissedUpdates: true).0)

        model.beginReplay(replayFrom: replayFromCursor)
        model.endReplay(succeeded: true)

        #expect(model.hasMissedUpdates)
    }

    @Test func aSuccessfulResumeWithNoReplayKeepsTheMark() {
        let model = SessionModelFixtures.immediateModel()
        model.attach(SessionModelFixtures.handMadeSubscription(hasMissedUpdates: true).0)

        model.beginReplay(replayFrom: nil)
        model.endReplay(succeeded: true)

        #expect(model.hasMissedUpdates)
    }

    // MARK: - Replay flags

    @Test func isReplayingIsTrueBetweenTheBeginAndTheEnd() {
        let model = SessionModelFixtures.immediateModel()
        #expect(!model.isReplaying)

        model.beginReplay(replayFrom: replayFromStart)
        #expect(model.isReplaying)

        model.endReplay(succeeded: true)
        #expect(!model.isReplaying)
    }

    @Test func isReplayingIsFalseAfterAFailedReplay() {
        let model = SessionModelFixtures.immediateModel()

        model.beginReplay(replayFrom: replayFromStart)
        model.endReplay(succeeded: false)

        #expect(!model.isReplaying)
    }

    @Test func theEndOfAReplayFlushesTheBufferedChunks() throws {
        let model = SessionModelFixtures.coalescingModel(clock: ManualClock())

        model.beginReplay(replayFrom: replayFromStart)
        model.apply(agentChunk(text: "replayed"))
        model.endReplay(succeeded: true)

        #expect(try #require(model.transcript.first?.agentMessage).content.joinedText == "replayed")
    }

    // MARK: - Replay marker

    @Test func theResumeMarkerEndsTheReplayAfterEachReplayedUpdate() async {
        let model = SessionModelFixtures.immediateModel()
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
        model.attach(subscription)
        model.beginReplay(replayFrom: replayFromStart)
        model.replayRequestDidStart(markedRequestId)

        for update in replayedUpdates {
            continuation.yield(.update(update))
        }
        continuation.yield(requestFinished(.succeeded))
        await model.waitForReplayEnd()

        #expect(!model.isReplaying)
        #expect(model.transcript.count == replayedEntryCount)
        #expect(model.history == .retained(replayFrom: replayFromStart))
    }

    @Test func aFailedResumeMarkerEndsTheReplayAsAFailure() async {
        let model = SessionModelFixtures.immediateModel()
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
        model.attach(subscription)
        model.beginReplay(replayFrom: replayFromStart)
        model.replayRequestDidStart(markedRequestId)

        continuation.yield(requestFinished(.failed))
        await model.waitForReplayEnd()

        #expect(!model.isReplaying)
        #expect(model.history == .live)
    }

    @Test func theResumeMarkerOfAnotherResumeRequestLeavesTheReplayRunning() async throws {
        let model = SessionModelFixtures.immediateModel()
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
        model.attach(subscription)
        model.beginReplay(replayFrom: replayFromStart)
        model.replayRequestDidStart(runningRequestId)

        continuation.yield(requestFinished(.failed))
        continuation.yield(.update(agentChunk(text: "after the marker")))
        try await waitUntil { !model.transcript.isEmpty }

        #expect(model.isReplaying)
    }

    @Test func aResumeMarkerThatComesBeforeTheStartOfItsRequestEndsTheReplayAtTheStart() async throws {
        let model = SessionModelFixtures.immediateModel()
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
        model.attach(subscription)
        model.beginReplay(replayFrom: replayFromStart)
        continuation.yield(requestFinished(.succeeded))
        continuation.yield(.update(agentChunk(text: "after the marker")))
        try await waitUntil { !model.transcript.isEmpty }
        try #require(model.isReplaying)

        model.replayRequestDidStart(markedRequestId)

        #expect(!model.isReplaying)
        #expect(model.history == .retained(replayFrom: replayFromStart))
    }

    @Test func theMarkerOfAnotherRequestLeavesTheReplayRunning() async throws {
        let model = SessionModelFixtures.immediateModel()
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
        model.attach(subscription)
        model.beginReplay(replayFrom: replayFromStart)

        continuation.yield(requestFinished(.succeeded, method: ClientRequestSpan.Method.prompt))
        continuation.yield(.update(agentChunk(text: "after the marker")))
        try await waitUntil { !model.transcript.isEmpty }

        #expect(model.isReplaying)
    }

    @Test func theEndOfTheSubscriptionEndsTheReplayAsAFailure() async {
        let model = SessionModelFixtures.immediateModel()
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
        model.attach(subscription)
        model.beginReplay(replayFrom: replayFromStart)

        continuation.finish()
        await model.waitForReplayEnd()

        #expect(!model.isReplaying)
        #expect(model.history == .live)
    }

    @Test func closeEndsTheReplayAsAFailure() {
        let model = SessionModelFixtures.immediateModel()
        model.beginReplay(replayFrom: replayFromStart)

        model.markClosed()

        #expect(!model.isReplaying)
        #expect(model.history == .live)
    }

    // MARK: - History

    @Test func aNewModelHasLiveHistory() {
        #expect(SessionModelFixtures.immediateModel().history == .live)
    }

    @Test func aSuccessfulReplayGivesTheRetainedHistoryOfItsCursor() {
        let model = SessionModelFixtures.immediateModel()

        model.beginReplay(replayFrom: replayFromStart)
        model.endReplay(succeeded: true)

        #expect(model.history == .retained(replayFrom: replayFromStart))
    }

    @Test func aResumeWithNoReplayKeepsLiveHistory() {
        let model = SessionModelFixtures.immediateModel()

        model.beginReplay(replayFrom: nil)
        model.endReplay(succeeded: true)

        #expect(model.history == .live)
    }

    @Test func aFailedReplayKeepsLiveHistory() {
        let model = SessionModelFixtures.immediateModel()

        model.beginReplay(replayFrom: replayFromStart)
        model.endReplay(succeeded: false)

        #expect(model.history == .live)
    }

    // MARK: - Second replay

    @Test func aSecondReplayGivesTheTranscriptOfOneReplay() throws {
        let once = SessionModelFixtures.immediateModel()
        replayFixture(into: once)
        let twice = SessionModelFixtures.immediateModel()
        replayFixture(into: twice)
        let firstAgentMessage = try #require(twice.transcript.dropFirst().first?.agentMessage)

        replayFixture(into: twice)

        #expect(twice.transcript.map(\.id) == once.transcript.map(\.id))
        let agentMessage = try #require(twice.transcript.dropFirst().first?.agentMessage)
        #expect(agentMessage.content.joinedText == "Hi there")
        #expect(agentMessage !== firstAgentMessage)
        #expect(twice.usage == SessionModelFixtures.usage)
        #expect(twice.agentState == once.agentState)
    }

    @Test func aReplayIntoAModelWithATranscriptClearsTheLastValueState() {
        let model = SessionModelFixtures.immediateModel()
        replayFixture(into: model)

        model.beginReplay(replayFrom: replayFromStart)

        #expect(model.transcript.isEmpty)
        #expect(model.usage == nil)
        #expect(model.agentState == nil)
    }

    @Test func aResumeWithNoReplayKeepsTheTranscript() {
        let model = SessionModelFixtures.immediateModel()
        replayFixture(into: model)

        model.beginReplay(replayFrom: nil)

        #expect(model.transcript.count == replayedEntryCount)
        #expect(model.usage == SessionModelFixtures.usage)
    }

    // MARK: - Replay after a compaction

    /// Expects two models to show the same session: the same transcript
    /// entries with the same message content, and the same last-value state.
    ///
    /// - Parameters:
    ///   - model: The model under test.
    ///   - reference: The model that shows the expected session.
    private static func expectSameSession(_ model: SessionModel, as reference: SessionModel) {
        #expect(model.transcript.map(\.id) == reference.transcript.map(\.id))
        #expect(model.messageContents == reference.messageContents)
        #expect(model.availableCommands == reference.availableCommands)
        #expect(model.sessionInfo == reference.sessionInfo)
        #expect(model.agentState == reference.agentState)
    }

    @Test func aReplayAfterACompactionGivesTheTranscriptOfAFreshReplay() {
        let fresh = SessionModelFixtures.immediateModel()
        replayFixture(compactedRecord, into: fresh)
        let reloaded = SessionModelFixtures.immediateModel()
        reloaded.applyEach(firstTurnUpdates + secondTurnUpdates)
        #expect(reloaded.transcript.map(\.id) != fresh.transcript.map(\.id))

        replayFixture(compactedRecord, into: reloaded)

        Self.expectSameSession(reloaded, as: fresh)
    }

    @Test func aLiveStreamOfARecordGivesTheTranscriptOfItsReplay() {
        let replayed = SessionModelFixtures.immediateModel()
        replayFixture(compactedRecord, into: replayed)
        let streamed = SessionModelFixtures.immediateModel()

        streamed.applyEach(compactedRecord)

        Self.expectSameSession(streamed, as: replayed)
    }

    @Test func aLiveChunkAfterAReplayAppendsToTheReplayedMessage() throws {
        let model = SessionModelFixtures.coalescingModel(clock: ManualClock())
        let userMessageId = MessageId(rawValue: "user-1")
        let agentMessageId = MessageId(rawValue: "agent-1")
        let running = SessionUpdate.stateUpdate(.running(RunningStateUpdate()))
        let turnSoFar = [agentChunk(text: "Hel"), agentChunk(text: "lo")]
        // The chunks of the turn so far stay in the buffer when the replay
        // starts.
        model.applyEach([userChunk(text: "Question"), running] + turnSoFar)

        let question = UserMessage(messageId: userMessageId, content: .value([textBlock("Question")]))
        replayFixture([.userMessage(question)] + turnSoFar + [running], into: model)
        model.apply(agentChunk(text: " world"))
        model.flushPendingChunks()

        #expect(model.transcript.map(\.id) == [.wire(.userMessage(userMessageId)), .wire(.agentMessage(agentMessageId))])
        #expect(try #require(model.transcript.last?.agentMessage).content == [textBlock("Hel"), textBlock("lo"), textBlock(" world")])
        #expect(model.agentState == .running(RunningStateUpdate()))
    }

    @Test func aPendingPermissionStaysPendingAcrossAReplay() async throws {
        let model = SessionModelFixtures.immediateModel()
        replayFixture(into: model)
        let permission = try await SessionModelFixtures.startPermission(on: model)

        replayFixture(compactedRecord, into: model)

        let pending = try #require(model.pendingPermissions.first)
        #expect(model.pendingPermissions.count == 1)
        model.selectPermission(pending.id, option: SessionModelFixtures.allowOption.optionId)
        let response = await permission.value
        #expect(response.outcome == .selected(SelectedPermissionOutcome(optionId: SessionModelFixtures.allowOption.optionId)))
    }

    @Test func anUpdateAfterAFailedReplayApplies() throws {
        let model = SessionModelFixtures.immediateModel()
        model.beginReplay(replayFrom: replayFromStart)
        model.endReplay(succeeded: false)

        model.apply(agentChunk(text: "live"))

        #expect(try #require(model.transcript.first?.agentMessage).content.joinedText == "live")
    }

    @Test func aReplayedToolCallTakesTheLinkOfAPendingElicitation() async throws {
        let model = SessionModelFixtures.immediateModel()
        replayFixture(into: model)
        let request = ElicitationFixtures.formRequest(
            scope: .session(ElicitationSessionScope(sessionId: testSession, toolCallId: replayedToolCallId))
        )
        let task = Task { await model.awaitElicitation(request) }
        try await waitUntil { !model.pendingElicitations.isEmpty }
        let pending = try #require(model.pendingElicitations.first)

        replayFixture(into: model)

        let entry = try #require(model.transcript.first { $0.toolCall != nil }?.toolCall)
        #expect(entry.linkedElicitationIDs == [pending.id])
        model.cancelAllPending()
        _ = await task.value
    }

    // MARK: - Close

    @Test func closeSetsIsClosed() {
        let model = SessionModelFixtures.immediateModel()
        #expect(!model.isClosed)

        model.markClosed()

        #expect(model.isClosed)
    }

    @Test func closeFlushesTheBufferedChunks() throws {
        let model = SessionModelFixtures.coalescingModel(clock: ManualClock())
        model.apply(agentChunk(text: "last words"))

        model.markClosed()

        #expect(try #require(model.transcript.first?.agentMessage).content.joinedText == "last words")
    }

    @Test func closeCancelsAPendingPermission() async throws {
        let model = SessionModelFixtures.immediateModel()
        let request = SessionModelFixtures.permissionRequest()
        let task = Task { await model.awaitPermissionDecision(for: request) }
        try await waitUntil { !model.pendingPermissions.isEmpty }

        model.markClosed()

        #expect(model.pendingPermissions.isEmpty)
        #expect(await task.value.outcome == .cancelled)
    }

    @Test func closeEndsTheUpdateTap() async {
        let model = SessionModelFixtures.immediateModel()
        var tap = model.updateTap().makeAsyncIterator()

        model.markClosed()

        #expect(await tap.next() == nil)
    }

    @Test func aTapMadeAfterCloseEndsAtOnce() async {
        let model = SessionModelFixtures.immediateModel()
        model.markClosed()

        var tap = model.updateTap().makeAsyncIterator()

        #expect(await tap.next() == nil)
    }

    @Test func closeCancelsTheStreamTask() async throws {
        let model = SessionModelFixtures.immediateModel()
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
        let termination = TerminationProbe()
        continuation.onTermination = { reason in termination.record(reason) }
        model.attach(subscription)

        model.markClosed()

        try await waitUntil { termination.wasCancelled }
    }

    @Test func releasingTheModelCancelsTheStreamTask() async throws {
        var model: SessionModel? = SessionModelFixtures.immediateModel()
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
        let termination = TerminationProbe()
        continuation.onTermination = { reason in termination.record(reason) }
        try #require(model).attach(subscription)

        model = nil

        try await waitUntil { termination.wasCancelled }
    }

    @Test func anUpdateAfterCloseChangesNothing() {
        let model = SessionModelFixtures.immediateModel()
        model.apply(agentChunk(text: "before"))

        model.markClosed()
        model.apply(agentChunk(text: " after"))
        model.apply(idleState(stopReason: .endTurn))

        #expect(model.transcript.count == 1)
        #expect(model.transcript.first?.agentMessage?.content.joinedText == "before")
        #expect(model.agentState == nil)
    }
}

/// Records how an `AsyncStream` terminated, across isolation domains.
private final class TerminationProbe: Sendable {
    /// Whether the stream terminated by cancellation.
    private let cancelled = Mutex(false)

    /// Whether the stream terminated by cancellation.
    var wasCancelled: Bool {
        cancelled.withLock { $0 }
    }

    /// Records one termination.
    ///
    /// - Parameter reason: The reason that the stream gave.
    func record(_ reason: AsyncStream<SessionStreamEvent>.Continuation.Termination) {
        guard case .cancelled = reason else { return }
        cancelled.withLock { $0 = true }
    }
}
