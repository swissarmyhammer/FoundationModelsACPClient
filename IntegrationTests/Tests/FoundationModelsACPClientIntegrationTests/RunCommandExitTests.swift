import Foundation
import FoundationModelsACP
import Testing

// These tests drive the real `acp-client` binary against a real foreign agent,
// and assert what `cli-plan.md` §8 and §9 promise: the answer on stdout, the
// exit code the outcome owes, and no agent process left behind.
//
// Everything is asserted from OUTSIDE the run. The exit code comes from the
// process table, the answer from the pipe, and the agent's pid from a file the
// agent wrote itself. Nothing here can import the binary's own types: SwiftPM
// builds an executable product for this test bundle to spawn, and it does not
// publish that target's module to an other package. So the `-` prompt argument
// is spelled again below, and the exit codes stand in ``SectionNineExitCode``,
// against the same sections of `cli-plan.md` the unit suite pins the binary to.

/// The number of minutes this file's suite allows itself.
///
/// Every test here spawns two real processes — the binary, and the agent it
/// starts — so a loaded machine must not fail a suite that is only slow. The
/// bound each test really rests on is ``TransportTestDeadline/limit``; this one
/// is the backstop that ends a wedged run rather than holding the package open.
private let runSuiteTimeLimitMinutes = 5

/// The prompt argument that names standard input rather than a prompt
/// (`cli-plan.md` §7, row 4).
///
/// Spelled here rather than read from the binary's
/// `PromptSource.standardInputArgument`, which this package cannot import.
private let standardInputPromptArgument = "-"

/// How one stub agent ends its turn.
///
/// The four cases are the four endings this suite can script, and the pid
/// assertion runs over every one of them: `cli-plan.md` §11 lets no agent
/// outlive the run, and a teardown that reaps after one ending and not after
/// another is exactly the leak that section forbids.
enum TurnEnding: CaseIterable, Sendable {
    /// The agent reported `end_turn`.
    case endTurn

    /// The agent reported `refusal`.
    case refusal

    /// The agent reported `cancelled`.
    case cancelled

    /// The agent went idle and reported no stop reason at all.
    case noStopReason

    /// The stop reason this ending reports, or `nil` for the ending that
    /// reports none.
    var stopReason: StopReason? {
        switch self {
        case .endTurn:
            .endTurn
        case .refusal:
            .refusal
        case .cancelled:
            .cancelled
        case .noStopReason:
            nil
        }
    }

    /// Writes the stub agent that ends its turn this way.
    ///
    /// - Parameter pidFile: Where the agent records its own pid.
    /// - Returns: The absolute path of the script; the caller removes it.
    /// - Throws: A JSON-encoding failure, or the write failure of the script.
    func makeAgent(pidFile: String) throws -> String {
        guard let stopReason else {
            return try makeIdleWithoutStopReasonAgent(pidFile: pidFile)
        }
        return try makeWellBehavedAgent(stopReason: stopReason, pidFile: pidFile)
    }
}

/// One row of the prompt-source table of `cli-plan.md` §7 that yields a prompt.
///
/// The fourth row — no argument, with standard input a terminal — yields no
/// prompt at all, so it is the usage test below and not a case here.
enum PromptRow: CaseIterable, Sendable {
    /// Row 1: a prompt argument that is not `-`.
    case argument

    /// Row 2: no prompt argument, and standard input a pipe or a file.
    case pipedStandardInput

    /// Row 4: a prompt argument of `-`, which reads standard input.
    case dashArgument

    /// The prompt text this row delivers to the agent.
    ///
    /// Each row carries text of its own, so a run that read the wrong row's
    /// prompt fails rather than passing on a shared string.
    var promptText: String {
        switch self {
        case .argument:
            "the argument prompt"
        case .pipedStandardInput:
            "the piped prompt"
        case .dashArgument:
            "the dash prompt"
        }
    }

    /// The prompt argument this row puts on the command line, or `nil` for a
    /// row that puts none there.
    var promptArgument: String? {
        switch self {
        case .argument:
            promptText
        case .pipedStandardInput:
            nil
        case .dashArgument:
            standardInputPromptArgument
        }
    }

    /// What this row gives the run on its standard input.
    var standardInput: CLIStandardInput {
        switch self {
        case .argument:
            .endOfFile
        case .pipedStandardInput, .dashArgument:
            .bytes(Data(promptText.utf8))
        }
    }
}

/// `acp-client run` end to end: the answer, the exit code, and the reap.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns real processes.
@Suite(
    "acp-client run exits",
    .serialized,
    .timeLimit(.minutes(runSuiteTimeLimitMinutes))
)
struct RunCommandExitTests {
    /// The prompt the tests that do not assert on the prompt send.
    private static let prompt = "write a haiku"

    /// The reply text the stub agent streams.
    ///
    /// It carries no trailing newline, because §8 asks for the answer bytes
    /// verbatim and the assertion below compares bytes.
    private static let answer = "The stub agent answered."

    /// The text that stands before the unique part of a pid file's name.
    private static let pidFileNamePrefix = "acp-client-agent-pid-"

    /// The text that stands before the unique part of a transcript file's name.
    private static let transcriptFileNamePrefix = "acp-client-agent-requests-"

    @Test("a well behaved agent writes the answer to stdout, and the run exits 0")
    func aWellBehavedAgentWritesTheAnswerAndTheRunSucceeds() async throws {
        let script = try makeWellBehavedAgent(answer: Self.answer, stopReason: .endTurn)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            runArguments(prompt: Self.prompt, script: script)
        )

        #expect(result.exitCode == SectionNineExitCode.success)
        #expect(
            result.standardOutput == Data(Self.answer.utf8),
            "stdout was \"\(String(decoding: result.standardOutput, as: UTF8.self))\""
        )
        #expect(
            result.standardError.isEmpty,
            "stderr was \"\(String(decoding: result.standardError, as: UTF8.self))\""
        )
    }

    @Test(
        "a stop reason exits with the code section 9 gives it",
        arguments: zip(
            [StopReason.refusal, StopReason.cancelled],
            [SectionNineExitCode.refusal, SectionNineExitCode.cancelled]
        )
    )
    func aStopReasonExitsWithItsSectionNineCode(
        stopReason: StopReason,
        expectedExitCode: Int32
    ) async throws {
        let script = try makeWellBehavedAgent(answer: Self.answer, stopReason: stopReason)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            runArguments(prompt: Self.prompt, script: script)
        )

        #expect(result.exitCode == expectedExitCode)
        #expect(result.standardOutput == Data(Self.answer.utf8))
    }

    @Test("an idle that reports no stop reason exits 0")
    func anIdleWithNoStopReasonSucceeds() async throws {
        let script = try makeIdleWithoutStopReasonAgent(answer: Self.answer)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            runArguments(prompt: Self.prompt, script: script)
        )

        #expect(result.exitCode == SectionNineExitCode.success)
        #expect(result.standardOutput == Data(Self.answer.utf8))
    }

    @Test("an agent command that is not on PATH exits 1 and says so on stderr")
    func anAgentCommandThatIsNotOnPathFails() async throws {
        let missingCommand = "acp-client-no-such-agent-\(UUID().uuidString)"

        let result = try await runAcpClient(["run", Self.prompt, "--", missingCommand])

        #expect(result.exitCode == SectionNineExitCode.failure)
        #expect(result.standardOutput.isEmpty)
        let reported = String(decoding: result.standardError, as: UTF8.self)
        #expect(reported.contains(missingCommand), "stderr was \"\(reported)\"")
    }

    @Test("no prompt, with standard input a terminal, exits 2 and leaves stdout empty")
    func noPromptWithATerminalIsAUsageError() async throws {
        let script = try makeWellBehavedAgent(answer: Self.answer)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            runArguments(prompt: nil, script: script),
            standardInput: .terminal
        )

        #expect(result.exitCode == SectionNineExitCode.usage)
        #expect(result.standardOutput.isEmpty)
        #expect(!result.standardError.isEmpty)
    }

    @Test("no agent process outlives the run", arguments: TurnEnding.allCases)
    func noAgentProcessOutlivesTheRun(ending: TurnEnding) async throws {
        let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try ending.makeAgent(pidFile: pidFile.path)
        defer { removeAgentScript(script) }

        _ = try await runAcpClient(runArguments(prompt: Self.prompt, script: script))

        let pid = try recordedAgentPid(in: pidFile)
        #expect(!processExists(pid), "the agent with pid \(pid) outlived the run")
    }

    @Test(
        "each section 7 prompt row delivers its prompt to the agent",
        arguments: PromptRow.allCases
    )
    func eachPromptRowDeliversItsPrompt(row: PromptRow) async throws {
        let transcript = temporaryFileURL(prefix: Self.transcriptFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let script = try makeWellBehavedAgent(answer: Self.answer, transcript: transcript.path)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            runArguments(prompt: row.promptArgument, script: script),
            standardInput: row.standardInput
        )

        #expect(result.exitCode == SectionNineExitCode.success)
        let received = try String(contentsOf: transcript, encoding: .utf8)
        #expect(received.contains(row.promptText), "the agent read \"\(received)\"")
    }
}
