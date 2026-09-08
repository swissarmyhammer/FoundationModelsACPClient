import Foundation
import Testing

// These tests drive the real `acp-client` binary against a real foreign agent
// and send it a real `SIGINT`, which is the whole of `cli-plan.md` §11: the
// first press cancels the turn and waits, the second ends the run at once,
// both exit 4, and neither leaves an agent behind.
//
// Nothing short of a real signal to a real child process measures this.
// `InterruptHandlerTests` proves the counting, and `TurnRunnerTests` proves
// what each press does to a turn over an in-memory pair; only a run of the
// built binary, signalled from outside it, can prove the four things that
// follow:
//
// - the binary does NOT die on the first press, which the default `SIGINT`
//   disposition would do;
// - the process exits 4, which §9 gives a cancelled turn;
// - the answer bytes that arrived BEFORE the press are still on descriptor 1,
//   because §11 prints the text that arrived;
// - the agent is gone, because §11 lets no agent outlive the run and names the
//   interrupt among the paths that holds on. The pid comes from a file the
//   agent wrote itself, so the reading is taken from outside the run.
//
// Every signal here waits on the agent's own transcript first. A signal that
// arrived before the prompt went out would reach a disposition this binary has
// not replaced yet, and one that arrived after the turn ended would reach
// nothing at all; either would let a broken binary pass. The transcript line
// naming `session/prompt` is a fact only a STARTED turn can produce.
//
// Nothing here can import the binary's own types, for the reason
// `TimeoutTests` states: the exit codes stand in ``SectionNineExitCode``.

/// The number of minutes this file's suite allows itself.
///
/// Every test here spawns two real processes — the binary, and the agent it
/// starts — so a loaded machine must not fail a suite that is only slow.
private let interruptSuiteTimeLimitMinutes = 5

/// The prompt every run in this file sends.
private let interruptPrompt = "write a haiku"

/// The reply text the stub agents in this file stream.
///
/// It carries no trailing newline, because §8 asks for the answer bytes
/// verbatim and the assertions below compare bytes.
private let interruptAnswer = "The stub agent answered."

/// The wire method whose arrival at the agent means the turn has started.
private let promptMethod = "session/prompt"

/// The wire method the first press sends, which the transcript must hold
/// after the run.
private let cancelMethod = "session/cancel"

/// The number of seconds ``secondInterruptRunBudget`` covers.
private let secondInterruptRunBudgetSeconds = 2

/// The longest a run that ends on the second press may take, from the spawn
/// to the exit.
///
/// §11 gives the second press the end of the run AT ONCE, so the whole run —
/// the spawn, the handshake, the prompt, the two presses and the reap — is
/// bounded by what happens BEFORE the presses, and none of that waits on the
/// agent. Two seconds is generous for it, and it stands far under the bound
/// `runAcpClient` puts on a run, so a binary that kept waiting after the
/// second press fails here as a slow run rather than as a killed one.
private let secondInterruptRunBudget: Duration = .seconds(secondInterruptRunBudgetSeconds)

/// How many presses the first-interrupt rows send.
private let oneInterrupt = 1

/// How many presses the second-interrupt row sends.
///
/// The two go out back to back. A `DispatchSourceSignal` COALESCES, so this
/// pair reaches the binary as one event carrying a count of two whenever the
/// machine is quick enough — which is exactly the shape §11's second press has
/// to survive.
private let twoInterrupts = 2

/// `acp-client run` under `Ctrl-C`: the cancellation, the exit code, the bytes
/// that already arrived, and the reap.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns real processes and signals one of them.
@Suite(
    "acp-client Ctrl-C",
    .serialized,
    .timeLimit(.minutes(interruptSuiteTimeLimitMinutes))
)
struct InterruptTests {
    /// The text that stands before the unique part of a pid file's name.
    private static let pidFileNamePrefix = "acp-client-interrupt-agent-pid-"

    /// The text that stands before the unique part of a transcript's name.
    private static let transcriptNamePrefix = "acp-client-interrupt-transcript-"

    /// Runs one bounded `acp-client run` and presses `Ctrl-C` in the middle of
    /// its turn.
    ///
    /// The press waits until the agent has recorded the `session/prompt`
    /// request, so it lands inside a live turn rather than before or after one.
    ///
    /// - Parameters:
    ///   - script: The stub-agent script to run.
    ///   - transcript: The transcript that script appends its requests to,
    ///     which is what says the turn has started.
    ///   - presses: How many times to send `SIGINT`.
    /// - Returns: The finished run.
    /// - Throws: Whatever the run itself threw.
    private static func runInterrupted(
        agent script: String,
        transcript: URL,
        presses: Int
    ) async throws -> CLIResult {
        try await runAcpClient(
            runArguments(prompt: interruptPrompt, script: script),
            signals: CLISignals(
                signal: SIGINT,
                count: presses,
                readiness: { transcriptHolds(transcript, method: promptMethod) }
            )
        )
    }

    /// §11 gives the first `Ctrl-C` a `session/cancel` and a wait, and §9 gives
    /// the `cancelled` stop reason that follows the code 4.
    ///
    /// The agent sends no `idle` update of its own and answers the
    /// cancellation with one carrying `cancelled`, so this run can only end at
    /// all if the notification really reached the agent — and a binary that
    /// died on the press instead would carry the signal's own status rather
    /// than 4. The transcript is read beside the exit code, so the
    /// cancellation stands in the agent's own record of what reached it, and
    /// not only in the ending it chose.
    @Test("one SIGINT cancels the turn and exits 4")
    func oneInterruptCancelsTheTurnAndExitsWithTheCancelledCode() async throws {
        let transcript = temporaryFileURL(prefix: Self.transcriptNamePrefix)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let script = try makeCancelAwareAgent(
            answer: interruptAnswer,
            transcript: transcript.path
        )
        defer { removeAgentScript(script) }

        let result = try await Self.runInterrupted(
            agent: script,
            transcript: transcript,
            presses: oneInterrupt
        )

        #expect(result.exitCode == SectionNineExitCode.cancelled)
        #expect(
            transcriptHolds(transcript, method: cancelMethod),
            "no \(cancelMethod) reached the agent before the exit"
        )
    }

    /// §11 prints the text that arrived, and §8 gives standard output the
    /// answer text and nothing else. Byte equality pins both halves at one
    /// time: the chunk is there, and no cursor escape and no newline stand
    /// beside it.
    @Test("the answer that arrived before the interrupt is still written")
    func theAnswerThatArrivedBeforeTheInterruptIsStillWritten() async throws {
        let transcript = temporaryFileURL(prefix: Self.transcriptNamePrefix)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let script = try makeCancelAwareAgent(
            answer: interruptAnswer,
            transcript: transcript.path
        )
        defer { removeAgentScript(script) }

        let result = try await Self.runInterrupted(
            agent: script,
            transcript: transcript,
            presses: oneInterrupt
        )

        #expect(
            result.standardOutput == Data(interruptAnswer.utf8),
            "stdout was \"\(String(decoding: result.standardOutput, as: UTF8.self))\""
        )
    }

    /// §11 lets no agent outlive the run, and it names the interrupt among the
    /// paths that holds on. The pid is read back from a file the agent wrote
    /// itself, so the reading is taken from outside the finished run.
    @Test("no agent process outlives a cancelled run")
    func noAgentProcessOutlivesACancelledRun() async throws {
        let transcript = temporaryFileURL(prefix: Self.transcriptNamePrefix)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try makeCancelAwareAgent(
            answer: interruptAnswer,
            pidFile: pidFile.path,
            transcript: transcript.path
        )
        defer { removeAgentScript(script) }

        let result = try await Self.runInterrupted(
            agent: script,
            transcript: transcript,
            presses: oneInterrupt
        )

        #expect(result.exitCode == SectionNineExitCode.cancelled)
        let pid = try recordedAgentPid(in: pidFile)
        expectAgentGroupIsGone(ledBy: pid, after: "the run")
    }

    /// §11 gives the second `Ctrl-C` the end of the run at once, and §9 still
    /// gives it the code 4.
    ///
    /// This agent IGNORES `session/cancel` and sends no `idle` update ever, so
    /// a binary that only cancelled and kept waiting would never come back and
    /// the run's own bound would kill it. The agent's pid is read back beside
    /// the exit code, because §11 asks the same thing of this path as of every
    /// other.
    ///
    /// Standard output is measured here as a PREFIX of the answer rather than
    /// as the whole of it, because §11 divides the two claims. "Prints the
    /// text that arrived" belongs to the FIRST press, which waits for the
    /// agent; the second press "ends the run at once", so a chunk still in
    /// flight when it lands has no moment left in which to be written, and a
    /// byte equality here would turn that race into a flaky row. The row that
    /// owns the whole-answer claim is
    /// ``theAnswerThatArrivedBeforeTheInterruptIsStillWritten()``.
    ///
    /// A prefix is still a deterministic §8 claim on this path, and it is the
    /// one §8 actually makes: standard output carries the answer bytes and
    /// nothing else. Empty and whole both pass, whichever side of the race the
    /// chunk lands on; a cursor escape, a spinner frame or a trailing newline
    /// fails, whichever side it lands on.
    ///
    /// The elapsed time is asserted beside the exit code, because "at once"
    /// is a claim about time: a binary that cancelled on the second press and
    /// then waited for an `idle` that never comes would still exit 4 when the
    /// run's own bound killed the agent under it.
    @Test("two SIGINTs end a run whose agent ignores the cancellation, and still exit 4")
    func twoInterruptsEndARunWhoseAgentIgnoresTheCancellation() async throws {
        let transcript = temporaryFileURL(prefix: Self.transcriptNamePrefix)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try makeNeverIdleAgent(
            answer: interruptAnswer,
            pidFile: pidFile.path,
            transcript: transcript.path
        )
        defer { removeAgentScript(script) }

        let clock = ContinuousClock()
        let started = clock.now
        let result = try await Self.runInterrupted(
            agent: script,
            transcript: transcript,
            presses: twoInterrupts
        )
        let elapsed = clock.now - started

        #expect(result.exitCode == SectionNineExitCode.cancelled)
        #expect(elapsed < secondInterruptRunBudget, "the run took \(elapsed)")
        #expect(
            Data(interruptAnswer.utf8).starts(with: result.standardOutput),
            "stdout was \"\(String(decoding: result.standardOutput, as: UTF8.self))\""
        )
        // §8 leaves a default run silent on stderr UNTIL it fails, and a run
        // that was cut short without a word is a run nobody can debug.
        #expect(!result.standardError.isEmpty, "an interrupted run must say so on stderr")
        let pid = try recordedAgentPid(in: pidFile)
        expectAgentGroupIsGone(ledBy: pid, after: "the run")
    }

    /// The handler changes nothing about a run no signal reaches. §11 replaces
    /// the `SIGINT` disposition for the whole of a run, and a binary that had
    /// broken its own exit path doing so would show it here.
    @Test("a run with no signal still exits 0")
    func aRunWithNoSignalStillExitsWithTheSuccessCode() async throws {
        let script = try makeWellBehavedAgent(answer: interruptAnswer)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            runArguments(prompt: interruptPrompt, script: script)
        )

        #expect(result.exitCode == SectionNineExitCode.success)
        #expect(result.standardOutput == Data(interruptAnswer.utf8))
    }
}
