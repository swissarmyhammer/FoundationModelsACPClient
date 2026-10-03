import Foundation
import FoundationModelsACP
import Observation
import Testing

@testable import FoundationModelsACPClient

// The tests of the chunk coalescing and the raw update tap of `SessionModel`.
// A manual clock controls the cadence, so no test reads the wall clock.

/// The number of rapid chunks that the write-count tests send.
private let rapidChunkCount = 200

/// The default cadence that the model must use, in milliseconds.
private let expectedDefaultCadenceMilliseconds = 33

/// The test cadence, in milliseconds.
private let testCadenceMilliseconds = 40

/// The cadence that these tests give the model under test.
private let testCadence: Duration = .milliseconds(testCadenceMilliseconds)

/// The message id that `agentChunk` gives by default.
private let agentMessageId = MessageId(rawValue: "agent-1")

/// The message id that `thoughtChunk` gives by default.
private let thoughtMessageId = MessageId(rawValue: "thought-1")

/// Chunks with combining marks, emoji, and white space, so a coalesced fold
/// that changed one byte would show.
private let mixedChunks = ["Hé", "llo,  ", "\n\t", "👋🏽 ", "cafe\u{301}", "  ", "end."]

/// Makes a model for the test session that coalesces on the test cadence.
///
/// - Parameter clock: The clock that schedules the flushes.
/// - Returns: The model.
@MainActor
private func coalescingModel(clock: ManualClock) -> SessionModel {
    SessionModel(sessionId: testSession, coalescingCadence: testCadence, clock: clock)
}

/// Counts each observable change of the values that `read` reads.
///
/// The tracker registers again inside each `onChange`, so it counts every
/// change one by one, as SwiftUI would see them with an immediate re-render.
///
/// - Parameters:
///   - read: The reads that the observation tracks.
///   - counter: The change count to increase.
@MainActor
private func countChanges(of read: @escaping @MainActor @Sendable () -> Void, into counter: MutationCounter) {
    withObservationTracking(read) {
        counter.increase()
        MainActor.assumeIsolated {
            countChanges(of: read, into: counter)
        }
    }
}

/// Returns the concatenated text of content blocks.
///
/// - Parameter content: The content of a message.
/// - Returns: The text of all text blocks, joined in order.
private func joinedText(_ content: [ContentBlock]) -> String {
    content
        .compactMap { block in
            guard case .text(let text) = block else { return nil }
            return text.text
        }
        .joined()
}

/// The coalescing tests, in one suite so that `swift test --filter
/// SessionModelCoalescingTests` selects them. A tap test that waits for an
/// update the model never yields would suspend forever, so the suite has a
/// time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionModelCoalescingTests {
    // MARK: - Cadence

    @Test func defaultCadenceIsThirtyThreeMilliseconds() {
        #expect(SessionModel.defaultCoalescingCadence == .milliseconds(expectedDefaultCadenceMilliseconds))
    }

    @Test func bufferedChunksWaitUntilTheCadenceElapses() async throws {
        let clock = ManualClock()
        let model = coalescingModel(clock: clock)

        model.apply(agentChunk(text: "one "))
        model.apply(agentChunk(text: "two"))
        #expect(model.transcript.isEmpty)

        await yieldUntil { clock.sleeperCount > 0 }
        clock.advance(by: testCadence)
        await yieldUntil { !model.transcript.isEmpty }

        let entry = try #require(model.transcript.first?.agentMessage)
        #expect(model.transcript.map(\.id) == [.wire(.agentMessage(agentMessageId))])
        #expect(joinedText(entry.content) == "one two")
    }

    @Test func zeroCadenceAppliesEachChunkAtOnce() throws {
        let clock = ManualClock()
        let model = SessionModel(sessionId: testSession, coalescingCadence: .zero, clock: clock)

        model.apply(agentChunk(text: "now"))

        #expect(try #require(model.transcript.first?.agentMessage).content == [textBlock("now")])
        #expect(clock.sleeperCount == 0)
    }

    // MARK: - Write count

    @Test func chunksInsideOneCadenceWriteTheEntryOneTime() throws {
        let model = coalescingModel(clock: ManualClock())
        model.apply(agentChunk(text: "first "))
        model.flushPendingChunks()
        let entry = try #require(model.transcript.first?.agentMessage)
        let writes = MutationCounter()
        countChanges(of: { _ = entry.content }, into: writes)

        for index in 0..<rapidChunkCount {
            model.apply(agentChunk(text: "token-\(index) "))
        }
        #expect(writes.value == 0)
        model.flushPendingChunks()

        #expect(writes.value == 1)
        #expect(entry.content.count == rapidChunkCount + 1)
    }

    @Test func chunksForANewEntryAppendTheTranscriptOneTime() throws {
        let model = coalescingModel(clock: ManualClock())
        let appends = MutationCounter()
        countChanges(of: { _ = model.transcript }, into: appends)

        for index in 0..<rapidChunkCount {
            model.apply(agentChunk(text: "token-\(index) "))
        }
        model.apply(idleState(stopReason: .endTurn))

        #expect(appends.value == 1)
        #expect(try #require(model.transcript.first?.agentMessage).content.count == rapidChunkCount)
    }

    @Test func coalescedTextEqualsOneByOneApplication() throws {
        let coalesced = coalescingModel(clock: ManualClock())
        let oneByOne = SessionModel(sessionId: testSession, coalescingCadence: .zero, clock: ManualClock())

        for chunk in mixedChunks {
            coalesced.apply(agentChunk(text: chunk))
            oneByOne.apply(agentChunk(text: chunk))
        }
        coalesced.flushPendingChunks()

        let coalescedContent = try #require(coalesced.transcript.first?.agentMessage).content
        #expect(coalescedContent == (try #require(oneByOne.transcript.first?.agentMessage)).content)
        #expect(joinedText(coalescedContent) == mixedChunks.joined())
    }

    // MARK: - Order

    @Test func aTurnEndFlushesTheBufferedRemainderSynchronously() throws {
        let model = coalescingModel(clock: ManualClock())

        model.apply(agentChunk(text: "partial "))
        model.apply(agentChunk(text: "tail"))
        #expect(model.transcript.isEmpty)
        // The clock never moves, so only the turn end can flush the buffer.
        model.apply(idleState(stopReason: .endTurn))

        #expect(joinedText(try #require(model.transcript.first?.agentMessage).content) == "partial tail")
        #expect(model.agentState == .idle(IdleStateUpdate(stopReason: .endTurn)))
    }

    @Test func aNonChunkUpdateAppliesAfterTheBufferedChunks() {
        let model = coalescingModel(clock: ManualClock())

        model.apply(agentChunk(text: "before the tool"))
        model.apply(toolCallStatus(id: "tool-1", .pending))

        #expect(
            model.transcript.map(\.id) == [
                .wire(.agentMessage(agentMessageId)), .wire(.toolCall(ToolCallId(rawValue: "tool-1"))),
            ]
        )
    }

    @Test func interleavedMessageAndThoughtChunksCoalesceIntoTheirOwnEntries() throws {
        let model = coalescingModel(clock: ManualClock())

        model.apply(thoughtChunk(text: "think-a "))
        model.apply(agentChunk(text: "say-a "))
        model.apply(thoughtChunk(text: "think-b"))
        model.apply(agentChunk(text: "say-b"))
        model.flushPendingChunks()

        #expect(model.transcript.map(\.id) == [.wire(.agentThought(thoughtMessageId)), .wire(.agentMessage(agentMessageId))])
        #expect(joinedText(try #require(model.transcript.first?.thought).content) == "think-a think-b")
        #expect(joinedText(try #require(model.transcript.last?.agentMessage).content) == "say-a say-b")
    }

    @Test func flushPendingChunksAppliesTheBufferAtOnce() throws {
        let model = coalescingModel(clock: ManualClock())

        model.apply(agentChunk(text: "left open"))
        // The clock never moves, so only the explicit flush can apply it.
        model.flushPendingChunks()

        #expect(joinedText(try #require(model.transcript.first?.agentMessage).content) == "left open")
    }

    // MARK: - Update tap

    @Test func updateTapYieldsEachUpdateInArrivalOrder() async {
        let model = coalescingModel(clock: ManualClock())
        var tap = model.updateTap().makeAsyncIterator()
        let updates = [
            thoughtChunk(text: "think"),
            agentChunk(text: "say"),
            toolCallStatus(id: "tool-1", .pending),
            idleState(stopReason: .endTurn),
        ]

        for update in updates {
            model.apply(update)
        }

        var received: [SessionUpdate] = []
        for _ in updates {
            if let update = await tap.next() {
                received.append(update)
            }
        }
        #expect(received == updates)
    }

    @Test func updateTapYieldsAChunkBeforeTheBufferFlushes() async {
        let model = coalescingModel(clock: ManualClock())
        var tap = model.updateTap().makeAsyncIterator()
        let chunk = agentChunk(text: "at once")

        model.apply(chunk)

        #expect(await tap.next() == chunk)
        #expect(model.transcript.isEmpty)
    }

    @Test func finishingTheTapsEndsEachStream() async {
        let model = coalescingModel(clock: ManualClock())
        var first = model.updateTap().makeAsyncIterator()
        var second = model.updateTap().makeAsyncIterator()

        model.finishUpdateTaps()

        #expect(await first.next() == nil)
        #expect(await second.next() == nil)
    }

    @Test func releasingTheModelEndsTheTap() async throws {
        var model: SessionModel? = coalescingModel(clock: ManualClock())
        var tap = try #require(model).updateTap().makeAsyncIterator()

        model = nil

        #expect(await tap.next() == nil)
    }
}
