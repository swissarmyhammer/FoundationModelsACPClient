import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the start time and the end time of each transcript entry. A
// manual wall clock gives each time, so no test reads the system date, and a
// manual clock controls the coalescing cadence.

/// The time from the start of an entry to the next step of a test, in seconds.
private let firstStep: TimeInterval = 3

/// The time of a second step of a test, in seconds.
private let secondStep: TimeInterval = 2

/// The number of chunks that the observation test sends.
private let chunkCount = 50

/// The id of the tool call that the tool-call tests use.
private let toolCallRawId = "tool-1"

/// The terminal id that the terminal test uses.
private let terminalId = TerminalId(rawValue: "terminal-1")

/// The type of the update that this schema revision does not know.
private let futureUpdateType = "future_update"

/// The text of the prompt that the prompt test sends.
private let promptText = "Hello agent"

/// The response that names the prompted user message.
private let promptedResponse = PromptResponse(messageId: MessageId(rawValue: "prompted-user-1"))

/// The timing tests, in one suite so that `swift test --filter
/// TranscriptEntryTimingTests` selects them. A test that waits for a prompt
/// the fake never receives would suspend forever, so the suite has a time
/// limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TranscriptEntryTimingTests {
    /// The wall clock that gives each time.
    let wallClock = ManualWallClock()

    /// The fake sender of the model under test.
    let sender = FakeSessionRequestSender()

    /// The date at which each test starts.
    let start = ManualWallClock.startDate

    /// Makes a model that sends its requests through ``sender`` and reads
    /// each time from ``wallClock``.
    ///
    /// - Parameter cadence: The coalescing cadence of the model. `.zero`
    ///   applies each chunk at once.
    /// - Returns: The model.
    func timedModel(cadence: Duration = .zero) -> SessionModel {
        SessionModelFixtures.makeModel(sender: sender, cadence: cadence, now: wallClock.now)
    }

    /// Makes a timed model that holds chunks in the buffer on the buffered
    /// cadence until a flush runs.
    ///
    /// - Returns: The model.
    func bufferedModel() -> SessionModel {
        timedModel(cadence: SessionModelFixtures.bufferedCadence)
    }

    // MARK: - Messages and thoughts

    @Test func agentMessageStartsAtItsFirstChunkAndEndsWhenTheNextEntryStarts() throws {
        let model = timedModel()

        model.apply(agentChunk(text: "one "))
        wallClock.advance(by: firstStep)
        model.apply(agentChunk(text: "two"))
        wallClock.advance(by: secondStep)
        model.apply(toolCallStatus(id: toolCallRawId, .pending))

        let message = try #require(model.transcript.first?.agentMessage)
        #expect(message.startedAt == start)
        #expect(message.endedAt == start + firstStep + secondStep)
        #expect(message.duration == firstStep + secondStep)
    }

    @Test func agentMessageHasNoEndWhileNoOtherEntryStarts() throws {
        let model = timedModel()

        model.apply(agentChunk(text: "still talking"))
        wallClock.advance(by: firstStep)

        let message = try #require(model.transcript.first?.agentMessage)
        #expect(message.endedAt == nil)
        #expect(message.duration == nil)
    }

    @Test func thoughtEndsWhenTheNextEntryStarts() throws {
        let model = timedModel()

        model.apply(thoughtChunk(text: "think"))
        wallClock.advance(by: firstStep)
        model.apply(agentChunk(text: "say"))

        let thought = try #require(model.transcript.first?.thought)
        #expect(thought.endedAt == start + firstStep)
        #expect(try #require(model.transcript.last?.agentMessage).startedAt == start + firstStep)
    }

    @Test func thoughtEndsWhenTheAgentBecomesIdle() throws {
        let model = timedModel()

        model.apply(thoughtChunk(text: "think"))
        wallClock.advance(by: firstStep)
        model.apply(idleState(stopReason: .endTurn))

        #expect(try #require(model.transcript.first?.thought).duration == firstStep)
    }

    @Test func aLaterEntryDoesNotMoveAnEndThatIsSet() throws {
        let model = timedModel()

        model.apply(thoughtChunk(text: "think"))
        wallClock.advance(by: firstStep)
        model.apply(idleState(stopReason: .endTurn))
        wallClock.advance(by: secondStep)
        model.apply(toolCallStatus(id: toolCallRawId, .pending))

        #expect(try #require(model.transcript.first?.thought).endedAt == start + firstStep)
    }

    @Test func unknownEntryEndsWhenTheNextEntryStarts() throws {
        let model = timedModel()

        model.apply(.unknown(futureUpdateType, .object([:])))
        wallClock.advance(by: firstStep)
        model.apply(agentChunk(text: "say"))

        #expect(try #require(model.transcript.first?.unknown).duration == firstStep)
    }

    // MARK: - Tool calls, terminals, compactions, and plans

    @Test(arguments: [ToolCallStatus.completed, .failed, .cancelled])
    func toolCallEndsWhenItsStatusFinishes(_ finished: ToolCallStatus) throws {
        let model = timedModel()

        model.apply(toolCallStatus(id: toolCallRawId, .pending))
        wallClock.advance(by: firstStep)
        model.apply(toolCallStatus(id: toolCallRawId, .inProgress))
        let toolCall = try #require(model.transcript.first?.toolCall)
        #expect(toolCall.endedAt == nil)
        wallClock.advance(by: secondStep)
        model.apply(toolCallStatus(id: toolCallRawId, finished))

        #expect(toolCall.startedAt == start)
        #expect(toolCall.endedAt == start + firstStep + secondStep)
    }

    @Test func aLaterToolCallUpdateDoesNotMoveItsEnd() throws {
        let model = timedModel()

        model.apply(toolCallStatus(id: toolCallRawId, .completed))
        wallClock.advance(by: firstStep)
        model.apply(toolCallStatus(id: toolCallRawId, .failed))

        #expect(try #require(model.transcript.first?.toolCall).endedAt == start)
    }

    @Test func toolCallDoesNotEndWhenTheNextEntryStarts() throws {
        let model = timedModel()

        model.apply(toolCallStatus(id: toolCallRawId, .inProgress))
        wallClock.advance(by: firstStep)
        model.apply(agentChunk(text: "while the tool runs"))
        model.apply(idleState(stopReason: .endTurn))

        #expect(try #require(model.transcript.first?.toolCall).endedAt == nil)
    }

    @Test func terminalEndsWhenItsExitStatusArrives() throws {
        let model = timedModel()

        model.apply(.terminalUpdate(TerminalUpdate(terminalId: terminalId, command: .value("ls"))))
        wallClock.advance(by: firstStep)
        model.apply(.terminalUpdate(TerminalUpdate(terminalId: terminalId, exitStatus: .value(TerminalExitStatus(exitCode: 0)))))

        #expect(try #require(model.transcript.first?.terminal).duration == firstStep)
    }

    @Test func compactionEndsWhenItsStatusFinishes() throws {
        let model = timedModel()

        model.apply(SessionModelFixtures.compactionUpdate(.inProgress))
        wallClock.advance(by: firstStep)
        model.apply(SessionModelFixtures.compactionUpdate(.completed))

        #expect(try #require(model.transcript.first?.compaction).duration == firstStep)
    }

    @Test func planHasNoEnd() throws {
        let model = timedModel()
        let plan = PlanUpdate(plan: .items(PlanItems(entries: [], planId: PlanId(rawValue: "plan-1"))))

        model.apply(.planUpdate(plan))
        wallClock.advance(by: firstStep)
        model.apply(agentChunk(text: "after the plan"))
        model.apply(idleState(stopReason: .endTurn))

        let entry = try #require(model.transcript.first?.plan)
        #expect(entry.startedAt == start)
        #expect(entry.endedAt == nil)
    }

    // MARK: - Local entries

    @Test func promptUserMessageStartsAndEndsWhenThePromptIsSent() async throws {
        let model = timedModel()
        model.apply(agentChunk(text: "earlier answer"))
        wallClock.advance(by: firstStep)

        let call = await model.startPrompt(promptText, heldBy: sender)
        wallClock.advance(by: secondStep)
        sender.answerPrompt(with: promptedResponse)
        _ = try await call.value

        let message = try #require(model.transcript.last?.userMessage)
        #expect(message.startedAt == start + firstStep)
        #expect(message.endedAt == start + firstStep)
        #expect(try #require(model.transcript.first?.agentMessage).endedAt == start + firstStep)
    }

    @Test func errorEntryStartsAndEndsWhenTheClientAddsIt() throws {
        let model = timedModel()
        wallClock.advance(by: firstStep)

        model.appendError(code: .internalError, message: "failed", data: nil)

        let entry = try #require(model.transcript.first?.error)
        #expect(entry.startedAt == start + firstStep)
        #expect(entry.duration == 0)
    }

    // MARK: - Replay

    @Test func entriesOfAReplayHaveNoTimes() {
        let model = timedModel()

        model.beginReplay(replayFrom: SessionModelFixtures.replayFromStart)
        model.applyEach([
            thoughtChunk(text: "think"),
            agentChunk(text: "say"),
            toolCallStatus(id: toolCallRawId, .completed),
            idleState(stopReason: .endTurn),
        ])
        model.endReplay(succeeded: true)

        #expect(model.transcript.count == 3)
        #expect(model.transcript.allSatisfy { $0.timing.startedAt == nil && $0.timing.endedAt == nil })
    }

    @Test func bufferedChunksOfAReplayHaveNoTimes() throws {
        let model = bufferedModel()

        model.beginReplay(replayFrom: SessionModelFixtures.replayFromStart)
        model.apply(agentChunk(text: "replayed"))
        model.endReplay(succeeded: true)

        let message = try #require(model.transcript.first?.agentMessage)
        #expect(message.startedAt == nil)
        #expect(message.endedAt == nil)
    }

    @Test func aLiveEntryAfterAReplayGetsTimesAndLeavesTheReplayedEntryOpen() throws {
        let model = timedModel()
        model.beginReplay(replayFrom: SessionModelFixtures.replayFromStart)
        model.apply(agentChunk(text: "replayed", message: "old"))
        model.endReplay(succeeded: true)

        model.apply(agentChunk(text: "live", message: "new"))

        #expect(try #require(model.transcript.first?.agentMessage).endedAt == nil)
        #expect(try #require(model.transcript.last?.agentMessage).startedAt == start)
    }

    // MARK: - Observation

    @Test func manyChunksOfOneMessageWriteEachTimeAtMostOneTime() throws {
        let model = bufferedModel()
        model.apply(agentChunk(text: "first "))
        model.flushPendingChunks()
        let message = try #require(model.transcript.first?.agentMessage)
        let startWrites = MutationCounter()
        let endWrites = MutationCounter()
        countChanges(of: { _ = message.startedAt }, into: startWrites)
        countChanges(of: { _ = message.endedAt }, into: endWrites)

        for index in 0..<chunkCount {
            wallClock.advance(by: firstStep)
            model.apply(agentChunk(text: "token-\(index) "))
            model.flushPendingChunks()
        }
        model.apply(idleState(stopReason: .endTurn))
        model.apply(agentChunk(text: "late chunk"))
        model.flushPendingChunks()

        #expect(startWrites.value == 0)
        #expect(endWrites.value == 1)
    }

    // MARK: - Connection model

    @Test func connectionModelGivesItsWallClockToEachSessionModel() throws {
        let connection = ConnectionModel(coalescingCadence: .zero, now: wallClock.now)
        let model = connection.makeSessionModel(sessionId: testSession, requestSender: sender)
        wallClock.advance(by: firstStep)

        model.apply(agentChunk(text: "say"))

        #expect(try #require(model.transcript.first?.agentMessage).startedAt == start + firstStep)
    }
}
