import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient
@testable import AcpClientCore

// These tests cover `TurnRunner`, the turn of `cli-plan.md` §8: one prompt,
// the answer streamed to a sink as it arrives, and the end of the turn read
// off the `idle` state update.
//
// Every test drives the runner over `InMemoryTransport.pair()` with a stub
// agent on the far end. `TurnRunner` holds no process handling — `RunCommand`
// owns the agent process — so no binary is started here and nothing waits on
// a pipe.
//
// Both packages export a type called `TerminalOutput`, and this file imports
// both, so the binary's terminal layer is named `AcpClientCore.TerminalOutput`
// in full. The wire package's `TerminalOutput` is the ACP model of an
// agent-owned terminal, and it has no part in these tests.
//
// The answer sink is a buffer of `Data`, and the assertions compare bytes.
// §8 asks for the answer bytes verbatim — no trailing newline, no colour, in
// a terminal and in a pipe alike — and only a byte comparison can prove that
// nothing was added.
//
// The terminal layer is built over a buffer sink and over a chosen answer to
// "is standard error a terminal", because a test process cannot make its own
// standard error a terminal and must not write to the real one.

/// The text every test in this file shares.
private enum TurnText {
    /// The prompt each test sends.
    static let prompt = "go"

    /// The first half of the answer one test asserts byte for byte.
    static let firstAnswerHalf = "Hello, "

    /// The second half of that answer.
    static let secondAnswerHalf = "world"

    /// The whole of that answer.
    static var wholeAnswer: String { firstAnswerHalf + secondAnswerHalf }

    /// The first half of a multi-byte answer.
    ///
    /// Every character that is more than one byte in UTF-8 is a chance for a
    /// runner that counted characters instead of bytes to lose one, and the
    /// split between the two halves is a chance for a runner that re-encoded
    /// each chunk on its own to lose the join.
    static let firstMultiByteHalf = "héllo "

    /// The second half of that multi-byte answer.
    static let secondMultiByteHalf = "wörld 🌍"

    /// The whole of that multi-byte answer.
    static var wholeMultiByteAnswer: String { firstMultiByteHalf + secondMultiByteHalf }

    /// The text of the thought chunk one test scripts beside the answer.
    static let thought = "the agent is thinking"

    /// The message id ``SessionUpdateFixtures`` stamps on a thought chunk.
    static let thoughtMessageID = MessageId(rawValue: "thought-1")

    /// The title of the tool call that runs BEFORE the first answer chunk.
    static let earlyToolName = "reading the early file"

    /// The title of the tool call that runs AFTER the first answer chunk.
    static let lateToolName = "reading the late file"

    /// Makes a tool-call update that carries a title and nothing else.
    ///
    /// - Parameters:
    ///   - id: The raw tool-call id.
    ///   - title: The human-readable title of the tool call.
    /// - Returns: The update.
    static func toolCallTitle(id: String, _ title: String) -> SessionUpdate {
        .toolCallUpdate(ToolCallUpdate(toolCallId: ToolCallId(rawValue: id), title: .value(title)))
    }
}

/// One row of the stop-reason table: what the agent put on its `idle` update,
/// and the outcome the turn owes.
struct IdleRow: Sendable, CustomStringConvertible {
    /// The stop reason the agent reported, or `nil` to report none.
    let stopReason: StopReason?

    /// The outcome the turn owes for that reported reason.
    let outcome: TurnOutcome

    /// A human-readable description of this row.
    var description: String {
        stopReason.map { "idle with \($0)" } ?? "idle with no stop reason"
    }
}

/// Each stop reason an agent can put on its `idle` update, beside the outcome
/// the turn owes.
///
/// The last row is the one the schema makes easy to get wrong:
/// `IdleStateUpdate.stopReason` is optional, and an agent that went idle
/// without saying why still went idle.
private let idleRows: [IdleRow] = [
    IdleRow(stopReason: .endTurn, outcome: .stopped(.endTurn)),
    IdleRow(stopReason: .refusal, outcome: .stopped(.refusal)),
    IdleRow(stopReason: .cancelled, outcome: .stopped(.cancelled)),
    IdleRow(stopReason: nil, outcome: .idleWithNoReason),
]

/// A ``TurnRunner`` over one end of an in-memory pair, with a
/// ``ScriptedStubAgent`` on the other end, a buffer standing for standard
/// error, and a buffer standing for standard output.
@MainActor
private struct TurnRunnerHarness {
    /// Everything the terminal layer wrote, in the chunks the sink received.
    let terminalBuffer: ThreadSafeBuffer<String>

    /// Every write the answer sink received, in order.
    let answerWrites: ThreadSafeBuffer<Data>

    /// The value under test.
    let runner: TurnRunner

    /// The connected seam, held so a test can read the observable container.
    let session: AgentSession

    /// The agent-side connection. A test holds it so the far end of the pair
    /// outlives the test body.
    let agentConnection: AgentSideConnection

    /// The answer bytes the sink received, end to end.
    var answer: Data {
        answerWrites.elements.reduce(into: Data()) { $0.append($1) }
    }

    /// Builds the runner over a fresh pair, a fresh stub and fresh buffers,
    /// and negotiates with the agent, which is what every caller of the seam
    /// does before it drives a turn.
    ///
    /// - Parameters:
    ///   - script: The updates the stub sends before it answers the prompt.
    ///   - deferredScript: The updates the stub sends after it answers the
    ///     prompt, one step per gate.
    ///   - standardErrorIsATerminal: The answer the injected terminal reading
    ///     gives, which stands in for `isatty` on file descriptor 2.
    /// - Throws: Whatever `initialize` threw.
    init(
        script: [SessionUpdate] = [],
        deferredScript: [GatedUpdates] = [],
        standardErrorIsATerminal: Bool = false
    ) async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: script,
                deferredScript: deferredScript
            )
        }
        let terminalBuffer = ThreadSafeBuffer<String>()
        let answerWrites = ThreadSafeBuffer<Data>()
        self.terminalBuffer = terminalBuffer
        self.answerWrites = answerWrites
        let terminal = AcpClientCore.TerminalOutput(
            verbosity: .normal,
            isStandardErrorATerminal: { standardErrorIsATerminal },
            sink: { terminalBuffer.append($0) }
        )
        session = await AgentSession(over: clientEnd, terminal: terminal, cwd: nil)
        _ = try await session.initialize()
        runner = TurnRunner(
            session: session,
            prompt: TurnText.prompt,
            terminal: terminal,
            answerSink: { answerWrites.append($0) }
        )
    }

    /// Tears the connection down, as every exit path of the binary does.
    func teardown() async {
        await session.teardown()
        withExtendedLifetime(agentConnection) {}
    }
}

@Suite("acp-client turn runner")
struct TurnRunnerTests {
    /// §8 keeps standard output for the answer text alone: the sink holds the
    /// chunks joined, and nothing else. No session id, no stop reason, and no
    /// trailing newline, which is why the comparison is on bytes.
    @MainActor @Test("the sink holds exactly the answer chunks", .timeLimit(.minutes(1)))
    func theSinkHoldsExactlyTheAnswerChunks() async throws {
        let harness = try await TurnRunnerHarness(script: [
            agentChunk(text: TurnText.firstAnswerHalf),
            agentChunk(text: TurnText.secondAnswerHalf),
            idleState(stopReason: .endTurn),
        ])

        _ = try await harness.runner.run()

        #expect(harness.answer == Data(TurnText.wholeAnswer.utf8))
        await harness.teardown()
    }

    /// The turn ends on the `idle` state update, and not at the prompt
    /// acknowledgement. In v2 `PromptResponse` carries only `meta`: it says
    /// the prompt was accepted, and it names no stop reason.
    ///
    /// The stub answers the prompt first and sends the rest behind two gates,
    /// so the wire order is the acknowledgement, then the answer chunk, then
    /// `idle`. The arrival of the chunk in the sink therefore PROVES the
    /// acknowledgement already reached the client, because it came earlier on
    /// the same stream. A runner that ended on the acknowledgement would have
    /// returned by then, and the outcome buffer would not be empty.
    @MainActor @Test("the turn ends on idle and not on the prompt answer", .timeLimit(.minutes(1)))
    func theTurnEndsOnIdleAndNotOnThePromptAnswer() async throws {
        let answerGate = UpdateGate()
        let idleGate = UpdateGate()
        let harness = try await TurnRunnerHarness(deferredScript: [
            GatedUpdates(gate: answerGate, updates: [agentChunk(text: TurnText.firstAnswerHalf)]),
            GatedUpdates(gate: idleGate, updates: [idleState(stopReason: .endTurn)]),
        ])
        let outcomes = ThreadSafeBuffer<TurnOutcome>()
        let turn = Task { @MainActor in
            let outcome = try await harness.runner.run()
            outcomes.append(outcome)
            return outcome
        }

        answerGate.open()
        #expect(await eventually { !harness.answer.isEmpty })
        #expect(outcomes.elements.isEmpty)

        idleGate.open()
        let outcome = try await turn.value
        #expect(outcome == .stopped(.endTurn))
        await harness.teardown()
    }

    /// An `idle` that carries a stop reason gives that reason, and an `idle`
    /// that carries none gives ``TurnOutcome/idleWithNoReason``. The end of
    /// the turn is read off `idle` ARRIVING, never off a value being present.
    @MainActor @Test("an idle update gives the outcome its stop reason owes", .timeLimit(.minutes(1)), arguments: idleRows)
    func anIdleUpdateGivesTheOutcomeItsStopReasonOwes(row: IdleRow) async throws {
        let harness = try await TurnRunnerHarness(script: [
            agentChunk(text: TurnText.firstAnswerHalf),
            idleState(stopReason: row.stopReason),
        ])

        let outcome = try await harness.runner.run()

        #expect(outcome == row.outcome, "\(row) gave the wrong outcome.")
        await harness.teardown()
    }

    /// A thought chunk is the agent's reasoning and not its answer, so §8
    /// keeps it off standard output. It still reaches the observable
    /// container behind the connection, which is where a UI reads it.
    @MainActor @Test("a thought chunk reaches the container and never the sink", .timeLimit(.minutes(1)))
    func aThoughtChunkReachesTheContainerAndNeverTheSink() async throws {
        let harness = try await TurnRunnerHarness(script: [
            thoughtChunk(text: TurnText.thought),
            agentChunk(text: TurnText.firstAnswerHalf),
            idleState(stopReason: .endTurn),
        ])

        _ = try await harness.runner.run()

        #expect(harness.answer == Data(TurnText.firstAnswerHalf.utf8))
        let state = harness.session.container.session(for: testSession)
        #expect(
            await eventually {
                state.flushPendingChunks()
                return state.messageContent(for: TurnText.thoughtMessageID)
                    == [textBlock(TurnText.thought)]
            }
        )
        await harness.teardown()
    }

    /// The stub sends its first chunk the moment the prompt lands, before it
    /// sends anything else and before it answers, so a runner that subscribed
    /// after it prompted would lose that chunk and leave the sink empty.
    @MainActor @Test("a chunk sent the instant the prompt lands is not lost", .timeLimit(.minutes(1)))
    func aChunkSentTheInstantThePromptLandsIsNotLost() async throws {
        let harness = try await TurnRunnerHarness(script: [
            agentChunk(text: TurnText.firstAnswerHalf),
            idleState(stopReason: .endTurn),
        ])

        _ = try await harness.runner.run()

        #expect(harness.answer == Data(TurnText.firstAnswerHalf.utf8))
        await harness.teardown()
    }

    /// The spinner runs from the prompt until the first chunk, and the
    /// running tool name goes out through the line the spinner rewrites in
    /// place.
    ///
    /// The two tool calls are what makes this discriminating: the early one
    /// runs while the spinner is up and must be drawn, and the late one runs
    /// after the first answer chunk, when the spinner is over, and must not
    /// be drawn.
    @MainActor @Test("the spinner runs from the prompt to the first answer chunk", .timeLimit(.minutes(1)))
    func theSpinnerRunsFromThePromptToTheFirstAnswerChunk() async throws {
        let harness = try await TurnRunnerHarness(
            script: [
                TurnText.toolCallTitle(id: "call-1", TurnText.earlyToolName),
                agentChunk(text: TurnText.firstAnswerHalf),
                TurnText.toolCallTitle(id: "call-2", TurnText.lateToolName),
                idleState(stopReason: .endTurn),
            ],
            standardErrorIsATerminal: true
        )

        _ = try await harness.runner.run()

        #expect(harness.terminalBuffer.text.contains(TurnText.earlyToolName))
        #expect(!harness.terminalBuffer.text.contains(TurnText.lateToolName))
        #expect(harness.answer == Data(TurnText.firstAnswerHalf.utf8))
        await harness.teardown()
    }

    /// §8 gives a pipe or a file nothing at all on standard error, so the
    /// same turn that draws a spinner on a terminal draws nothing here.
    @MainActor @Test("the spinner draws nothing when standard error is not a terminal", .timeLimit(.minutes(1)))
    func theSpinnerDrawsNothingWhenStandardErrorIsNotATerminal() async throws {
        let harness = try await TurnRunnerHarness(
            script: [
                TurnText.toolCallTitle(id: "call-1", TurnText.earlyToolName),
                agentChunk(text: TurnText.firstAnswerHalf),
                idleState(stopReason: .endTurn),
            ],
            standardErrorIsATerminal: false
        )

        _ = try await harness.runner.run()

        #expect(harness.terminalBuffer.text.isEmpty)
        await harness.teardown()
    }

    /// The answer is bytes, so a multi-byte answer split across two chunks
    /// reaches the sink as the concatenation of the two, byte for byte.
    @MainActor @Test("a multi-byte answer split across two chunks arrives whole", .timeLimit(.minutes(1)))
    func aMultiByteAnswerSplitAcrossTwoChunksArrivesWhole() async throws {
        let harness = try await TurnRunnerHarness(script: [
            agentChunk(text: TurnText.firstMultiByteHalf),
            agentChunk(text: TurnText.secondMultiByteHalf),
            idleState(stopReason: .endTurn),
        ])

        _ = try await harness.runner.run()

        #expect(harness.answer == Data(TurnText.wholeMultiByteAnswer.utf8))
        await harness.teardown()
    }
}
