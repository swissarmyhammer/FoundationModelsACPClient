import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the compaction entry of `SessionModel`. The unstable
// `compaction_update` and `compaction_summary_chunk` updates go through the
// merge engine, and land in one `CompactionEntry` object. A compaction
// changes only the model context of the agent, so it never changes an
// earlier entry of the transcript.

/// The engine identity of the test compaction.
private let compactionEntryID = TranscriptEntry.ID.wire(.compaction(SessionModelFixtures.compactionId))

/// The engine identity of the agent message that comes before the
/// compaction.
private let earlierMessageID = TranscriptEntry.ID.wire(.agentMessage(MessageId(rawValue: "agent-1")))

/// The reason of the failed compaction.
private let failureReason = "The context window is too small."

/// The `sessionUpdate` wire type of a compaction update.
private let compactionUpdateType = "compaction_update"

/// The replay cursor that asks for the full retained history.
private let replayFromStart: ReplayFrom = .start(ReplayFromStart())

/// The compaction tests, in one suite so that `swift test --filter
/// SessionModelCompactionTests` selects them.
@MainActor
struct SessionModelCompactionTests {
    // MARK: - Add

    @Test func aCompactionUpdateAddsOneCompactionEntryAtTheEnd() throws {
        let model = SessionModelFixtures.immediateModel()

        model.applyEach([agentChunk(text: "Earlier"), SessionModelFixtures.compactionUpdate(.inProgress)])

        let entry = try #require(model.transcript.last?.compaction)
        #expect(model.transcript.map(\.id) == [earlierMessageID, compactionEntryID])
        #expect(entry.compactionId == SessionModelFixtures.compactionId)
        #expect(entry.status == .inProgress)
        #expect(entry.hasReportedStatus)
        #expect(entry.summary.isEmpty)
        #expect(entry.error == nil)
        #expect(entry.origin == .wire)
    }

    // MARK: - Status

    @Test func aLaterUpdateChangesTheStatusOfTheSameObject() throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(SessionModelFixtures.compactionUpdate(.inProgress))
        let entry = try #require(model.transcript.first?.compaction)

        model.apply(SessionModelFixtures.compactionUpdate(.completed, summary: .value([textBlock("Kept")])))

        #expect(model.transcript.map(\.id) == [compactionEntryID])
        #expect(model.transcript.first?.compaction === entry)
        #expect(entry.status == .completed)
        #expect(entry.summary == [textBlock("Kept")])
    }

    @Test func aStatusChangeWritesOnlyTheStatus() throws {
        let model = SessionModelFixtures.immediateModel()
        model.applyEach([
            SessionModelFixtures.compactionUpdate(.inProgress),
            SessionModelFixtures.compactionChunk("Kept"),
        ])
        let entry = try #require(model.transcript.first?.compaction)
        let statusChange = SessionModelFixtures.compactionUpdate(.completed, summary: .value([textBlock("Kept")]))

        let fired = observationFires {
            _ = (entry.summary, entry.error, entry.meta)
        } during: {
            model.apply(statusChange)
        }

        #expect(!fired)
        #expect(entry.status == .completed)
    }

    @Test func aFailedCompactionKeepsItsError() throws {
        let model = SessionModelFixtures.immediateModel()

        model.applyEach([
            SessionModelFixtures.compactionUpdate(.inProgress),
            SessionModelFixtures.compactionUpdate(.failed, error: .value(failureReason)),
        ])

        let entry = try #require(model.transcript.first?.compaction)
        #expect(entry.status == .failed)
        #expect(entry.error == failureReason)
    }

    @Test func aCancelledCompactionHasTheCancelledStatus() throws {
        let model = SessionModelFixtures.immediateModel()

        model.applyEach([
            SessionModelFixtures.compactionUpdate(.inProgress),
            SessionModelFixtures.compactionUpdate(.cancelled),
        ])

        let entry = try #require(model.transcript.first?.compaction)
        #expect(entry.status == .cancelled)
        #expect(entry.hasReportedStatus)
    }

    // MARK: - Summary

    @Test func summaryChunksAppendToTheSummary() throws {
        let model = SessionModelFixtures.immediateModel()

        model.applyEach([
            SessionModelFixtures.compactionUpdate(.inProgress),
            SessionModelFixtures.compactionChunk("First "),
            SessionModelFixtures.compactionChunk("second"),
        ])

        let entry = try #require(model.transcript.first?.compaction)
        #expect(model.transcript.map(\.id) == [compactionEntryID])
        #expect(entry.summary == [textBlock("First "), textBlock("second")])
    }

    @Test func aChunkBeforeAnyUpdateGivesNoReportedStatus() throws {
        let model = SessionModelFixtures.immediateModel()

        model.apply(SessionModelFixtures.compactionChunk("Early"))

        let entry = try #require(model.transcript.first?.compaction)
        #expect(entry.status == SessionEntry.Compaction.unreportedStatus)
        #expect(!entry.hasReportedStatus)
        #expect(entry.summary == [textBlock("Early")])
    }

    @Test func anEmptySummaryClearsTheSummary() throws {
        let model = SessionModelFixtures.immediateModel()

        model.applyEach([
            SessionModelFixtures.compactionUpdate(.inProgress),
            SessionModelFixtures.compactionChunk("Kept"),
            SessionModelFixtures.compactionUpdate(.completed, summary: .value([])),
        ])

        let entry = try #require(model.transcript.first?.compaction)
        #expect(entry.summary.isEmpty)
    }

    @Test func aNullSummaryClearsTheSummary() throws {
        let model = SessionModelFixtures.immediateModel()

        model.applyEach([
            SessionModelFixtures.compactionUpdate(.inProgress),
            SessionModelFixtures.compactionChunk("Kept"),
            SessionModelFixtures.compactionUpdate(.completed, summary: .cleared),
        ])

        let entry = try #require(model.transcript.first?.compaction)
        #expect(entry.summary.isEmpty)
    }

    // MARK: - Earlier entries

    @Test func aCompactionDoesNotChangeAnEarlierEntry() throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(agentChunk(text: "Earlier"))
        let earlier = try #require(model.transcript.first?.agentMessage)
        let compaction = [
            SessionModelFixtures.compactionUpdate(.inProgress),
            SessionModelFixtures.compactionChunk("Summary"),
            SessionModelFixtures.compactionUpdate(.completed),
        ]

        let fired = observationFires {
            _ = earlier.content
            _ = earlier.messageId
            _ = earlier.meta
        } during: {
            model.applyEach(compaction)
        }

        #expect(!fired)
        #expect(model.transcript.first?.agentMessage === earlier)
        #expect(earlier.content == [textBlock("Earlier")])
        #expect(model.transcript.map(\.id) == [earlierMessageID, compactionEntryID])
    }

    // MARK: - Malformed payload

    @Test func aMalformedCompactionUpdateBecomesAnUnknownEntry() throws {
        let model = SessionModelFixtures.immediateModel()
        let payload = JSONValue.object(["compactionId": .string(SessionModelFixtures.compactionId.rawValue)])

        model.apply(.unknown(compactionUpdateType, payload))

        let entry = try #require(model.transcript.first?.unknown)
        #expect(entry.type == compactionUpdateType)
        #expect(entry.raw == payload)
    }

    // MARK: - Replay

    @Test func aReplayGivesTheSameCompactionEntry() throws {
        let updates = [
            agentChunk(text: "Earlier"),
            SessionModelFixtures.compactionUpdate(.inProgress),
            SessionModelFixtures.compactionChunk("Summary"),
            SessionModelFixtures.compactionUpdate(.failed, error: .value(failureReason)),
        ]
        var agentHistory = SessionMergeEngine()
        for update in updates {
            agentHistory.apply(update)
        }
        let model = SessionModelFixtures.immediateModel()
        model.applyEach(updates)

        model.beginReplay(replayFrom: replayFromStart)
        model.applyEach(agentHistory.transcriptUpdates)
        model.endReplay(succeeded: true)

        let entry = try #require(model.transcript.last?.compaction)
        #expect(model.transcript.map(\.id) == [earlierMessageID, compactionEntryID])
        #expect(entry.status == .failed)
        #expect(entry.summary == [textBlock("Summary")])
        #expect(entry.error == failureReason)
    }
}
