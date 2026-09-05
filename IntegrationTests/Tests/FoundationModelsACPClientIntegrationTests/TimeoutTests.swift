import Foundation
import FoundationModelsACP
import Testing

// These tests drive the real `acp-client` binary against a real foreign agent
// and assert the `--timeout` rows of `cli-plan.md` §6.1, §8, §9 and §11, one
// test for each acceptance row of the card.
//
// The limit is a claim about a WHOLE RUN, and that is why these tests exist
// beside the unit ones. `TurnRunnerTests` proves the turn throws
// `AcpClientTimeout` at its limit, over an in-memory pair; only a run of the
// built binary, watched from outside it, can prove the three things that
// follow from the throw:
//
// - the process exits 124, which is the `timeout(1)` convention §9 adopts;
// - the answer bytes that arrived BEFORE the limit are still on descriptor 1,
//   because §8 gives standard output the answer text and a limit is not a
//   reason to discard what the agent already sent;
// - the agent is gone, because §11 lets no agent outlive the run and names the
//   timeout path among the paths that holds on. The pid comes from a file the
//   agent wrote itself, so the reading is taken from outside the run.
//
// Nothing here can import the binary's own types: SwiftPM builds an executable
// product for this test bundle to spawn, and it publishes no module to an other
// package. The exit codes stand in ``SectionNineExitCode``, against the same §9
// rows the unit suite's `ExitCodeTests` pins the binary to.

/// The number of minutes this file's suite allows itself.
///
/// Every test here spawns two real processes — the binary, and the agent it
/// starts — so a loaded machine must not fail a suite that is only slow. The
/// bound each test really rests on is ``TransportTestDeadline/limit``; this one
/// is the backstop that ends a wedged run rather than holding the package open.
private let timeoutSuiteTimeLimitMinutes = 5

/// The prompt every run in this file sends.
///
/// No test here asserts on the prompt — `RunCommandExitTests` owns the
/// prompt-source table — so one text serves them all.
private let timeoutPrompt = "write a haiku"

/// The reply text the stub agents in this file stream.
///
/// It carries no trailing newline, because §8 asks for the answer bytes
/// verbatim and the assertions below compare bytes.
private let timeoutAnswer = "The stub agent answered."

/// How long the slow stub agent waits before it ends its turn.
///
/// It is far longer than ``shortTimeoutValue``, so the same agent reaches the
/// limit under that option and runs to its stop reason without it. Three
/// seconds is short beside the bound `runAcpClient` puts on a whole run, and
/// `/bin/sh` hands the wait to `sleep`, which reads whole seconds.
private let slowTurnDelaySeconds = 3

/// The `--timeout` value the runs that mean to reach the limit carry.
///
/// Half a second is far shorter than ``slowTurnDelaySeconds``, and far longer
/// than the handshake and the one answer chunk that stand before it. So a run
/// under it reaches the limit with the answer already written and with nothing
/// left that could still arrive.
private let shortTimeoutValue = "0.5"

/// The `--timeout` value the run that must NOT reach the limit carries.
///
/// It stands well beyond the bound `runAcpClient` puts on the whole run, so
/// that test fails as a wrong exit code rather than as a limit reached.
private let generousTimeoutValue = "120"

/// The `--timeout` value the run against an agent that goes away carries.
///
/// Five seconds is far longer than that whole run — a spawn, a handshake and
/// one chunk — and shorter than the bound `runAcpClient` puts on a run, so a
/// run that waited this limit out fails on ``goingAwayRunBudget`` rather than
/// being killed as a hang.
private let goingAwayTimeoutValue = "5"

/// The longest a run against an agent that goes away mid-turn may take.
///
/// The run has nothing left to wait for the moment the agent is gone, so two
/// seconds is generous for it. It is also far under ``goingAwayTimeoutValue``,
/// so a run that ended only when its limit did fails here.
private let goingAwayRunBudget: Duration = .seconds(2)

/// The `--timeout` values that give the turn no time to run in.
///
/// Zero is a limit that has already passed at the moment the turn starts, and a
/// negative limit passed before that. §9 makes each of them the usage error.
private let meaninglessTimeoutValues = ["0", "-1"]

/// `acp-client run --timeout`: the limit, the exit code, the bytes that already
/// arrived, and the reap.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns real processes.
@Suite(
    "acp-client --timeout",
    .serialized,
    .timeLimit(.minutes(timeoutSuiteTimeLimitMinutes))
)
struct TimeoutTests {
    /// The text that stands before the unique part of a pid file's name.
    private static let pidFileNamePrefix = "acp-client-timeout-agent-pid-"

    /// Runs one bounded `acp-client run` against an agent that never goes idle.
    ///
    /// Three of the rows below read one and the same run — the exit code, the
    /// bytes on standard output, and the agent's pid — so the run is built in
    /// one place and each test asserts on its own part of it.
    ///
    /// - Parameter pidFile: Where the agent records its own pid, or `nil` to
    ///   record none.
    /// - Returns: The finished run.
    /// - Throws: A JSON-encoding failure, the write failure of the script, or
    ///   whatever the run itself threw.
    private static func runAgainstAnAgentThatNeverGoesIdle(
        pidFile: String? = nil
    ) async throws -> CLIResult {
        let script = try makeNeverIdleAgent(answer: timeoutAnswer, pidFile: pidFile)
        defer { removeAgentScript(script) }

        return try await runAcpClient(
            runArguments(
                prompt: timeoutPrompt,
                options: timeoutOption(shortTimeoutValue),
                script: script
            )
        )
    }

    /// §6.1 defaults `--timeout` to no limit, so a slow agent is not a stuck
    /// one: the run waits it out and ends on the agent's own `idle`.
    @Test("with no --timeout, a slow agent still runs to its stop reason")
    func aSlowAgentWithNoTimeoutRunsToItsStopReason() async throws {
        let script = try makeSlowTurnAgent(
            answer: timeoutAnswer,
            stopReason: .endTurn,
            delaySeconds: slowTurnDelaySeconds
        )
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            runArguments(prompt: timeoutPrompt, script: script)
        )

        #expect(result.exitCode == SectionNineExitCode.success)
        #expect(
            result.standardOutput == Data(timeoutAnswer.utf8),
            "stdout was \"\(String(decoding: result.standardOutput, as: UTF8.self))\""
        )
    }

    /// §9 gives a run that reached its limit the code 124. The agent sends one
    /// chunk and then no `state_update` at all, so nothing but the limit can
    /// end this run.
    @Test("an agent that never goes idle ends the run at the limit, and exits 124")
    func anAgentThatNeverGoesIdleExitsWithTheTimeoutCode() async throws {
        let result = try await Self.runAgainstAnAgentThatNeverGoesIdle()

        #expect(result.exitCode == SectionNineExitCode.timeout)
        // §8 leaves a default run silent on stderr UNTIL it fails, and a run
        // that ended at its limit without a word is a run nobody can debug.
        #expect(
            !result.standardError.isEmpty,
            "a run that reached its limit must say so on stderr"
        )
    }

    /// §8 gives standard output the answer text and nothing else, and a limit
    /// is no reason to discard what the agent already sent. Byte equality is
    /// what pins both halves at one time: the chunk is there, and nothing
    /// stands beside it.
    @Test("the answer that arrived before the limit is still written")
    func theAnswerThatArrivedBeforeTheLimitIsStillWritten() async throws {
        let result = try await Self.runAgainstAnAgentThatNeverGoesIdle()

        #expect(
            result.standardOutput == Data(timeoutAnswer.utf8),
            "stdout was \"\(String(decoding: result.standardOutput, as: UTF8.self))\""
        )
    }

    /// §11 lets no agent outlive the run, and it names the timeout among the
    /// paths that holds on. The pid is read back from a file the agent wrote
    /// itself, so the reading is taken from outside the finished run.
    @Test("no agent process outlives a run that reached its limit")
    func noAgentProcessOutlivesATimeout() async throws {
        let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let result = try await Self.runAgainstAnAgentThatNeverGoesIdle(pidFile: pidFile.path)

        #expect(result.exitCode == SectionNineExitCode.timeout)
        let pid = try recordedAgentPid(in: pidFile)
        #expect(!processExists(pid), "the agent with pid \(pid) outlived the run")
    }

    /// §9 gives a mistake on the command line the code 2, and a limit that is
    /// not more than zero seconds gives the turn no time to run in at all.
    @Test(
        "a --timeout that is not more than zero exits 2 and leaves stdout empty",
        arguments: meaninglessTimeoutValues
    )
    func aTimeoutThatIsNotMoreThanZeroIsAUsageError(value: String) async throws {
        let script = try makeWellBehavedAgent(answer: timeoutAnswer)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            runArguments(
                prompt: timeoutPrompt,
                options: timeoutOption(value),
                script: script
            )
        )

        #expect(result.exitCode == SectionNineExitCode.usage)
        #expect(result.standardOutput.isEmpty)
        #expect(!result.standardError.isEmpty)
    }

    /// A run that ended inside its limit exits with the code its stop reason
    /// owes. The stop reason is `refusal`, so the assertion tells the right
    /// code from the timeout row AND from the success row at one time.
    @Test("a run that finishes inside its limit exits with its stop reason's code")
    func aRunThatFinishesInsideItsLimitKeepsItsStopReasonCode() async throws {
        let script = try makeWellBehavedAgent(answer: timeoutAnswer, stopReason: .refusal)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            runArguments(
                prompt: timeoutPrompt,
                options: timeoutOption(generousTimeoutValue),
                script: script
            )
        )

        #expect(result.exitCode == SectionNineExitCode.refusal)
        #expect(result.standardOutput == Data(timeoutAnswer.utf8))
    }

    /// An agent that goes away in the middle of the turn reached NO limit, so
    /// §9 owes that run the protocol-failure row and never the timeout row. The
    /// agent streams one chunk, answers the prompt, and then exits with no
    /// `state_update` at all.
    ///
    /// The elapsed time is asserted beside the exit code, because the two
    /// halves are one defect: a run that reported the limit here also WAITED
    /// the whole limit out, with nothing left that could ever arrive.
    @Test("an agent that goes away mid-turn fails at once, and does not wait out the limit")
    func anAgentThatGoesAwayMidTurnFailsAtOnce() async throws {
        let script = try makeExitingMidTurnAgent(answer: timeoutAnswer)
        defer { removeAgentScript(script) }

        let clock = ContinuousClock()
        let started = clock.now
        let result = try await runAcpClient(
            runArguments(
                prompt: timeoutPrompt,
                options: timeoutOption(goingAwayTimeoutValue),
                script: script
            )
        )
        let elapsed = clock.now - started

        #expect(result.exitCode == SectionNineExitCode.failure)
        #expect(elapsed < goingAwayRunBudget, "the run took \(elapsed)")
        #expect(result.standardOutput == Data(timeoutAnswer.utf8))
    }
}
