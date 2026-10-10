import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the transient notices of `SessionModel`. A `notice` is a live
// event and not session history: the model keeps it in `notices` and never
// in `transcript`, the merge engine does not replay it, and the start of a
// replay and the close of the model clear the list.

/// The warning notice that most tests receive.
private let contextNotice = Notice(
    severity: .warning,
    title: "The context is almost full",
    description: "The agent compacts the context soon.",
    meta: .object(["source": .string("test")])
)

/// A second notice, to tell two notices apart.
private let rateNotice = Notice(severity: .info, title: "The rate limit resets in one minute")

/// The time on the manual clock between the model init and the notice, in
/// milliseconds.
private let arrivalMilliseconds = 250

/// The replay cursor that asks for the full retained history.
private let replayFromStart: ReplayFrom = .start(ReplayFromStart())

/// The notice tests, in one suite so that `swift test --filter
/// SessionModelNoticeTests` selects them. A tap that never yields would
/// suspend forever, so the suite has a time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionModelNoticeTests {
    // MARK: - Add

    @Test func aNoticeAddsOneItemAndNoTranscriptEntry() throws {
        let model = SessionModelFixtures.immediateModel()

        model.apply(SessionModelFixtures.noticeUpdate(contextNotice))

        let notice = try #require(model.notices.first)
        #expect(model.notices.map(\.notice) == [contextNotice])
        #expect(notice.severity == .warning)
        #expect(notice.title == contextNotice.title)
        #expect(notice.description == contextNotice.description)
        #expect(notice.meta == contextNotice.meta)
        #expect(model.transcript.isEmpty)
    }

    @Test func aNoticeHasItsArrivalTimeOnTheInjectedClock() throws {
        let clock = ManualClock()
        let model = SessionModelFixtures.coalescingModel(clock: clock)

        clock.advance(by: .milliseconds(arrivalMilliseconds))
        model.apply(SessionModelFixtures.noticeUpdate(contextNotice))

        #expect(model.notices.map(\.arrivalTime) == [.milliseconds(arrivalMilliseconds)])
    }

    @Test func eachNoticeHasItsOwnId() throws {
        let model = SessionModelFixtures.immediateModel()

        model.applyEach([
            SessionModelFixtures.noticeUpdate(contextNotice),
            SessionModelFixtures.noticeUpdate(contextNotice),
        ])

        #expect(Set(model.notices.map(\.id)).count == model.notices.count)
        #expect(model.notices.map(\.notice) == [contextNotice, contextNotice])
    }

    // MARK: - Dismiss

    @Test func dismissNoticeRemovesOnlyThatNotice() throws {
        let model = SessionModelFixtures.immediateModel()
        model.applyEach([
            SessionModelFixtures.noticeUpdate(contextNotice),
            SessionModelFixtures.noticeUpdate(rateNotice),
        ])
        let first = try #require(model.notices.first)

        model.dismissNotice(first.id)

        #expect(model.notices.map(\.notice) == [rateNotice])
    }

    @Test func dismissNoticeWithAnUnknownIdChangesNothing() throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(SessionModelFixtures.noticeUpdate(contextNotice))
        let dismissed = try #require(model.notices.first)
        model.dismissNotice(dismissed.id)
        model.apply(SessionModelFixtures.noticeUpdate(rateNotice))

        model.dismissNotice(dismissed.id)

        #expect(model.notices.map(\.notice) == [rateNotice])
    }

    // MARK: - Replay and close

    @Test func theStartOfAResumeClearsTheNotices() throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(SessionModelFixtures.noticeUpdate(contextNotice))

        model.beginReplay(replayFrom: nil)

        #expect(model.notices.isEmpty)
    }

    @Test func aReplayDoesNotBringBackANotice() throws {
        let updates = [agentChunk(text: "Hello"), SessionModelFixtures.noticeUpdate(contextNotice)]
        var agentHistory = SessionMergeEngine()
        for update in updates {
            agentHistory.apply(update)
        }
        let model = SessionModelFixtures.immediateModel()
        model.applyEach(updates)

        model.beginReplay(replayFrom: replayFromStart)
        model.applyEach(agentHistory.transcriptUpdates)
        model.endReplay(succeeded: true)

        #expect(model.notices.isEmpty)
        #expect(model.transcript.map(\.id) == [.wire(.agentMessage(MessageId(rawValue: "agent-1")))])
    }

    @Test func theCloseClearsTheNotices() throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(SessionModelFixtures.noticeUpdate(contextNotice))

        model.markClosed()

        #expect(model.notices.isEmpty)
    }

    // MARK: - Update tap

    @Test func theUpdateTapGivesTheRawNoticeAndCompactionUpdates() async throws {
        let model = SessionModelFixtures.immediateModel()
        var tap = model.updateTap().makeAsyncIterator()
        let notice = SessionModelFixtures.noticeUpdate(contextNotice)
        let compaction = SessionModelFixtures.compactionUpdate(.inProgress)
        let chunk = SessionModelFixtures.compactionChunk("Summary")

        model.applyEach([notice, compaction, chunk])

        #expect(await tap.next() == notice)
        #expect(await tap.next() == compaction)
        #expect(await tap.next() == chunk)
    }
}
