import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The unit tests of `ChunkCoalescer`, the one chunk buffer that
// `SessionModel` and `ACPSessionState` share. A manual clock controls the
// cadence, so no test reads the wall clock.

/// The default cadence that the coalescer must use, in milliseconds.
private let expectedDefaultCadenceMilliseconds = 33

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

/// The owner side of a coalescer: it records each call, in order.
@MainActor
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
@Suite(.timeLimit(.minutes(1)))
struct ChunkCoalescerTests {
    // MARK: - Cadence

    @Test func defaultCadenceIsThirtyThreeMilliseconds() {
        #expect(ChunkCoalescer.defaultCadence == .milliseconds(expectedDefaultCadenceMilliseconds))
    }

    @Test func chunksWaitUntilTheCadenceElapsesThenFoldAsOneBatch() async {
        let clock = ManualClock()
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: testCadence, clock: clock)
        let first = agentChunk(text: "one ")
        let second = thoughtChunk(text: "two")

        coalescer.receive(first)
        coalescer.receive(second)
        #expect(owner.calls.isEmpty)

        await yieldUntil { clock.sleeperCount > 0 }
        clock.advance(by: testCadence)
        await yieldUntil { !owner.calls.isEmpty }

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

    @Test func flushFoldsTheBufferAtOnceAndCancelsTheScheduledFlush() async {
        let clock = ManualClock()
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: testCadence, clock: clock)
        let chunk = agentChunk(text: "now")
        coalescer.receive(chunk)
        await yieldUntil { clock.sleeperCount > 0 }

        coalescer.flush()
        #expect(owner.calls == [.foldChunks([chunk])])

        await yieldUntil { clock.sleeperCount == 0 }
        clock.advance(by: testCadence)
        await yieldUntil { owner.calls.count > 1 }
        #expect(owner.calls == [.foldChunks([chunk])])
    }

    @Test func flushOfAnEmptyBufferFoldsNothing() {
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: testCadence, clock: ManualClock())

        coalescer.flush()

        #expect(owner.calls.isEmpty)
    }

    @Test func chunksAfterAFlushStartANewCadence() async {
        let clock = ManualClock()
        let owner = RecordingOwner()
        let coalescer = owner.makeCoalescer(cadence: testCadence, clock: clock)
        let first = agentChunk(text: "one")
        let second = agentChunk(text: "two")
        coalescer.receive(first)
        coalescer.flush()

        coalescer.receive(second)
        await yieldUntil { clock.sleeperCount > 0 }
        clock.advance(by: testCadence)
        await yieldUntil { owner.calls.count > 1 }

        #expect(owner.calls == [.foldChunks([first]), .foldChunks([second])])
    }

    @Test func releasedCoalescerNeverFolds() async {
        let clock = ManualClock()
        let owner = RecordingOwner()
        var coalescer: ChunkCoalescer? = owner.makeCoalescer(cadence: testCadence, clock: clock)
        coalescer?.receive(agentChunk(text: "lost"))
        await yieldUntil { clock.sleeperCount > 0 }

        coalescer = nil
        await yieldUntil { clock.sleeperCount == 0 }
        clock.advance(by: testCadence)
        await yieldUntil { !owner.calls.isEmpty }

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
