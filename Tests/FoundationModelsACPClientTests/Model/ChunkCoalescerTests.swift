import Foundation
import FoundationModelsACP
import Observation
import Testing

@testable import FoundationModelsACPClient

// The unit tests of `ChunkCoalescer`, the chunk buffer of `SessionModel`. A
// manual clock controls the cadence, so no test reads the wall clock.
//
// The flush task of the coalescer is private, and these tests have no
// connection and no session. So no observable event tells that the coalescer
// starts no sleeper, or that its flush task does not fold. These waits use
// `noFailureEvent`, and each one is a known limit of rule T1.
//
// A cancel of the flush task runs the cancel handler of the clock at once, in
// the call to `cancel()`, so the sleeper is gone when the cancel returns. The
// tests check that with `#require` before they continue, and do not wait.

/// The test cadence, in milliseconds.
private let testCadenceMilliseconds = 40

/// The cadence that these tests give the coalescer under test.
private let testCadence: Duration = .milliseconds(testCadenceMilliseconds)

/// One call that the coalescer made into its owner.
private enum OwnerCall: Equatable {
    /// The coalescer folded these buffered chunks as one batch.
    case foldChunks([SessionUpdate])

    /// The coalescer applied this one update at once.
    case applyUpdate(SessionUpdate)
}

/// The owner side of a coalescer: it records each call, in order. It is
/// observable, so a test waits for a call with no poll.
@MainActor @Observable
private final class RecordingOwner {
    /// The calls that the coalescer made, in order.
    private(set) var calls: [OwnerCall] = []

    /// Makes a coalescer that calls this owner.
    ///
    /// - Parameters:
    ///   - cadence: The cadence between coalesced flushes.
    ///   - clock: The clock that schedules the flushes.
    /// - Returns: The coalescer.
    func makeCoalescer(cadence: Duration, clock: ManualClock) -> ChunkCoalescer {
        ChunkCoalescer(
            cadence: cadence,
            clock: clock,
            foldChunks: { [weak self] chunks in self?.calls.append(.foldChunks(chunks)) },
            applyUpdate: { [weak self] update in self?.calls.append(.applyUpdate(update)) }
        )
    }
}

/// The coalescer tests, in one suite so that `swift test --filter
/// ChunkCoalescerTests` selects them.
@MainActor
@Suite
struct ChunkCoalescerTests {
    // MARK: - Cadence

    @Test func chunksWaitUntilTheCadenceElapsesThenFoldAsOneBatch() async throws {
        let clock = ManualClock()
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: testCadence, clock: clock)
        let first = agentChunk(text: "one ")
        let second = thoughtChunk(text: "two")

        coalescer.receive(first)
        coalescer.receive(second)
        #expect(owner.calls.isEmpty)

        // No failure event: the flush task is private (see the file note).
        try await waitUntil({ clock.sleeperCount > 0 }, orFailWhen: noFailureEvent)
        clock.advance(by: testCadence)
        // No failure event: the flush task is private (see the file note).
        try await waitUntil({ !owner.calls.isEmpty }, orFailWhen: noFailureEvent)

        #expect(owner.calls == [.foldChunks([first, second])])
    }

    @Test func zeroCadenceAppliesEachChunkAtOnce() {
        let clock = ManualClock()
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: .zero, clock: clock)
        let chunk = agentChunk(text: "now")

        coalescer.receive(chunk)

        #expect(owner.calls == [.applyUpdate(chunk)])
        #expect(clock.sleeperCount == 0)
    }

    // MARK: - Order

    @Test func otherUpdateFlushesTheBufferBeforeItApplies() {
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: testCadence, clock: ManualClock())
        let chunk = agentChunk(text: "partial")
        let state = idleState(stopReason: .endTurn)

        coalescer.receive(chunk)
        coalescer.receive(state)

        #expect(owner.calls == [.foldChunks([chunk]), .applyUpdate(state)])
    }

    @Test func otherUpdateWithAnEmptyBufferOnlyApplies() {
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: testCadence, clock: ManualClock())
        let user = userChunk(text: "hi")

        coalescer.receive(user)

        #expect(owner.calls == [.applyUpdate(user)])
    }

    // MARK: - Flush

    @Test func flushFoldsTheBufferAtOnceAndCancelsTheScheduledFlush() async throws {
        let clock = ManualClock()
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: testCadence, clock: clock)
        let chunk = agentChunk(text: "now")
        coalescer.receive(chunk)
        // No failure event: the flush task is private (see the file note).
        try await waitUntil({ clock.sleeperCount > 0 }, orFailWhen: noFailureEvent)

        coalescer.flush()
        #expect(owner.calls == [.foldChunks([chunk])])

        // The cancel removes the sleeper of the scheduled flush, and a
        // cancelled flush task returns before it folds. With no sleeper, the
        // advance resumes nothing, so no second fold can come.
        try #require(clock.sleeperCount == 0)
        clock.advance(by: testCadence)
        #expect(owner.calls == [.foldChunks([chunk])])
    }

    @Test func flushOfAnEmptyBufferFoldsNothing() {
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: testCadence, clock: ManualClock())

        coalescer.flush()

        #expect(owner.calls.isEmpty)
    }

    @Test func chunksAfterAFlushStartANewCadence() async throws {
        let clock = ManualClock()
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: testCadence, clock: clock)
        let first = agentChunk(text: "one")
        let second = agentChunk(text: "two")
        coalescer.receive(first)
        coalescer.flush()

        coalescer.receive(second)
        // No failure event: the flush task is private (see the file note).
        try await waitUntil({ clock.sleeperCount > 0 }, orFailWhen: noFailureEvent)
        clock.advance(by: testCadence)
        // No failure event: the flush task is private (see the file note).
        try await waitUntil({ owner.calls.count > 1 }, orFailWhen: noFailureEvent)

        #expect(owner.calls == [.foldChunks([first]), .foldChunks([second])])
    }

    @Test func releasedCoalescerNeverFolds() async throws {
        let clock = ManualClock()
        let owner = RecordingOwner()
        var coalescer: ChunkCoalescer? = owner.makeCoalescer(cadence: testCadence, clock: clock)
        coalescer?.receive(agentChunk(text: "lost"))
        // No failure event: the flush task is private (see the file note).
        try await waitUntil({ clock.sleeperCount > 0 }, orFailWhen: noFailureEvent)

        // The release cancels the scheduled flush, and the cancel removes its
        // sleeper. With no sleeper, the advance resumes nothing.
        coalescer = nil
        try #require(clock.sleeperCount == 0)
        clock.advance(by: testCadence)

        #expect(owner.calls.isEmpty)
        #expect(clock.sleeperCount == 0)
    }

    // MARK: - Coalescible cases

    @Test func onlyTheTwoAgentChunkCasesCoalesce() {
        #expect(ChunkCoalescer.isCoalescible(agentChunk(text: "a")))
        #expect(ChunkCoalescer.isCoalescible(thoughtChunk(text: "b")))
        #expect(!ChunkCoalescer.isCoalescible(userChunk(text: "c")))
        #expect(!ChunkCoalescer.isCoalescible(idleState(stopReason: .endTurn)))
    }
}
