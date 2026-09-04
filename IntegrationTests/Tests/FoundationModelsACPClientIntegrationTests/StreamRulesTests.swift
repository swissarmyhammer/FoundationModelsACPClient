import Foundation
import FoundationModelsACP
import Testing

// These tests drive the real `acp-client` binary against a real foreign agent
// and assert the stdout-and-stderr split of `cli-plan.md` §8, one test for each
// acceptance row of the card.
//
// §8 is a claim about FILE DESCRIPTORS, and that is why these tests exist at
// all. The unit suites drive the turn logic over an in-memory pair, and a
// buffer sink there cannot see a byte that went straight to descriptor 1 — a
// Noora default that started writing to standard output, say. Only a run of the
// built binary, with both descriptors captured from outside it, can.
//
// Every assertion reads `Data` and not `String`. §8 asks for the answer bytes
// verbatim — nothing added, no trailing newline, no colour, in a terminal and
// in a pipe alike — and byte-for-byte is the only way to check that.
//
// Nothing here can import the binary's own types: SwiftPM builds an executable
// product for this test bundle to spawn, and it publishes no module to an other
// package. So the exit code and the two direction marks are spelled again
// below, against the same sections of `cli-plan.md` the unit suite pins the
// binary to.

/// The number of minutes this file's suite allows itself.
///
/// Every test here spawns two real processes — the binary, and the agent it
/// starts — so a loaded machine must not fail a suite that is only slow. The
/// bound each test really rests on is ``TransportTestDeadline/limit``; this one
/// is the backstop that ends a wedged run rather than holding the package open.
private let streamSuiteTimeLimitMinutes = 5

/// The exit code `cli-plan.md` §9 gives a turn that ended.
///
/// Spelled here rather than read from the binary's `AcpClientExitCode`, which
/// this package cannot import. The unit suite's `ExitCodeTests` pins that table
/// against the same §9 rows.
private let sectionNineSuccess: Int32 = 0

/// The prompt every run in this file sends.
///
/// No test here asserts on the prompt — `RunCommandExitTests` owns the
/// prompt-source table — so one text serves them all.
private let streamPrompt = "write a haiku"

/// The reply text the stub agents in this file stream.
///
/// It carries no trailing newline, because §8 asks for the answer bytes
/// verbatim and every assertion below compares bytes.
private let streamAnswer = "The stub agent answered."

/// The direction mark `--frames` puts before each line the agent sent.
///
/// The two marks are spelled here rather than read from the binary's
/// `FrameTeeTransport`, which this package cannot import. The unit suite's
/// `FrameTeeTransportTests` pins them against the same `cli-plan.md` §6.1 row.
private let inboundFrameMark = "<< "

/// The direction mark `--frames` puts before each line this client sent.
private let outboundFrameMark = ">> "

/// The `method` member of the first message the client ever sends, as it stands
/// on the wire.
///
/// A `--frames` run must show it under ``outboundFrameMark``, because that is
/// the whole claim of §6.1: the exchange is visible in both directions.
private let initializeMethodMember = #""method":"initialize""#

/// Renders one captured stream as text.
///
/// The assertions compare BYTES; this is for the line splitting a few of them
/// do, and for the failure message that says what the stream really held.
///
/// - Parameter stream: The captured bytes.
/// - Returns: The bytes as text, with invalid UTF-8 replaced rather than
///   dropped.
private func text(_ stream: Data) -> String {
    String(decoding: stream, as: UTF8.self)
}

/// Splits one captured stream into its non-empty lines.
///
/// - Parameter stream: The captured bytes.
/// - Returns: The lines, without their terminators.
private func lines(of stream: Data) -> [String] {
    text(stream).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

/// `acp-client run` and the two file descriptors: what reaches standard output,
/// and what reaches standard error under each option of `cli-plan.md` §6.1.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns real processes.
@Suite(
    "acp-client stream rules",
    .serialized,
    .timeLimit(.minutes(streamSuiteTimeLimitMinutes))
)
struct StreamRulesTests {
    /// The text that stands before the unique part of an arguments file's name.
    private static let argumentsFileNamePrefix = "acp-client-agent-argv-"

    /// The agent's own arguments one test passes through the `--` separator.
    ///
    /// They carry a long flag with a value and a short flag on their own,
    /// because §6 promises the agent keeps its own flags and a list of plain
    /// words would prove nothing about that.
    private static let agentArguments = ["--model", "small", "-v"]

    /// Builds the command line of one `run` against a stub-agent script.
    ///
    /// The scripts carry no execute bit, so the agent command is the shell and
    /// the script is its first argument, which is also the shape `cli-plan.md`
    /// §6 gives an agent that takes arguments of its own.
    ///
    /// - Parameters:
    ///   - options: The §6.1 options to put before the separator.
    ///   - script: The absolute path of the stub-agent script.
    ///   - agentArguments: The agent's own arguments, after the script.
    /// - Returns: The arguments for ``runAcpClient(_:standardInput:standardOutput:environment:)``.
    private static func runArguments(
        options: [String] = [],
        script: String,
        agentArguments: [String] = []
    ) -> [String] {
        ["run", streamPrompt] + options
            + ["--", stubAgentShellCommand, script] + agentArguments
    }

    @Test("stdout holds the answer text and nothing else, byte for byte")
    func stdoutHoldsTheAnswerTextAlone() async throws {
        let script = try makeWellBehavedAgent(answer: streamAnswer)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(Self.runArguments(script: script))

        #expect(result.exitCode == sectionNineSuccess)
        // Byte equality is what pins "add no trailing newline": one extra byte
        // fails this, and a `String` comparison would not.
        #expect(
            result.standardOutput == Data(streamAnswer.utf8),
            "stdout was \(result.standardOutput.count) bytes: \"\(text(result.standardOutput))\""
        )
    }

    @Test("a default run writes zero bytes to standard error")
    func aDefaultRunWritesNothingToStandardError() async throws {
        let script = try makeWellBehavedAgent(answer: streamAnswer)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(Self.runArguments(script: script))

        #expect(result.exitCode == sectionNineSuccess)
        #expect(
            result.standardError.isEmpty,
            "stderr was \(result.standardError.count) bytes: \"\(text(result.standardError))\""
        )
    }

    @Test("--quiet writes zero bytes to standard error and leaves stdout unchanged")
    func quietWritesNothingToStandardError() async throws {
        let script = try makeWellBehavedAgent(answer: streamAnswer)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            Self.runArguments(options: ["--quiet"], script: script)
        )

        #expect(result.exitCode == sectionNineSuccess)
        #expect(result.standardOutput == Data(streamAnswer.utf8))
        #expect(
            result.standardError.isEmpty,
            "stderr was \(result.standardError.count) bytes: \"\(text(result.standardError))\""
        )
    }

    @Test("--verbose writes session event lines to standard error and leaves stdout unchanged")
    func verboseWritesSessionEventsToStandardError() async throws {
        let script = try makeWellBehavedAgent(answer: streamAnswer)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            Self.runArguments(options: ["--verbose"], script: script)
        )

        #expect(result.exitCode == sectionNineSuccess)
        #expect(result.standardOutput == Data(streamAnswer.utf8))
        let reported = text(result.standardError)
        // The two facts §8 keeps OFF standard output: who answered
        // `initialize`, and which session the agent opened.
        #expect(reported.contains(stubAgentName), "stderr was \"\(reported)\"")
        #expect(reported.contains(stubAgentSessionID.rawValue), "stderr was \"\(reported)\"")
    }

    @Test("--frames writes the ndJSON messages to standard error in both directions")
    func framesWritesEveryMessageToStandardError() async throws {
        let script = try makeWellBehavedAgent(answer: streamAnswer)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            Self.runArguments(options: ["--frames"], script: script)
        )

        #expect(result.exitCode == sectionNineSuccess)
        #expect(result.standardOutput == Data(streamAnswer.utf8))
        let reported = lines(of: result.standardError)
        let outbound = reported.filter { $0.hasPrefix(outboundFrameMark) }
        let inbound = reported.filter { $0.hasPrefix(inboundFrameMark) }
        #expect(
            outbound.contains { $0.contains(initializeMethodMember) },
            "no outbound line carried the initialize request: \(reported)"
        )
        #expect(
            inbound.contains { $0.contains(stubAgentSessionID.rawValue) },
            "no inbound line carried the agent's session id: \(reported)"
        )
        // Every line carried a direction mark, so nothing else reached standard
        // error under the flag.
        #expect(outbound.count + inbound.count == reported.count, "stderr held \(reported)")
    }

    @Test("a permission request during the turn writes exactly one line to standard error")
    func aPermissionRequestWritesExactlyOneLine() async throws {
        let script = try makePermissionRequestingAgent(answer: streamAnswer)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(Self.runArguments(script: script))

        #expect(result.exitCode == sectionNineSuccess)
        #expect(result.standardOutput == Data(streamAnswer.utf8))
        let reported = lines(of: result.standardError)
        #expect(reported.count == 1, "stderr held \(reported)")
        #expect(
            reported.first?.contains(stubAgentPermissionTitle) == true,
            "stderr held \(reported)"
        )
    }

    @Test("the arguments after the separator reach the agent unchanged, flags included")
    func theArgumentsAfterTheSeparatorReachTheAgentUnchanged() async throws {
        let argumentsFile = temporaryFileURL(prefix: Self.argumentsFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: argumentsFile) }
        let script = try makeWellBehavedAgent(
            answer: streamAnswer,
            argumentsFile: argumentsFile.path
        )
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            Self.runArguments(script: script, agentArguments: Self.agentArguments)
        )

        #expect(result.exitCode == sectionNineSuccess)
        let received = try String(contentsOf: argumentsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(received == Self.agentArguments, "the agent read \(received)")
    }

    @Test("the answer bytes are the same with stdout a pipe and with stdout a file")
    func theAnswerIsTheSameOnAPipeAndOnAFile() async throws {
        let script = try makeWellBehavedAgent(answer: streamAnswer)
        defer { removeAgentScript(script) }

        let piped = try await runAcpClient(
            Self.runArguments(script: script),
            standardOutput: .pipe
        )
        let filed = try await runAcpClient(
            Self.runArguments(script: script),
            standardOutput: .file
        )

        #expect(piped.exitCode == sectionNineSuccess)
        #expect(filed.exitCode == sectionNineSuccess)
        #expect(piped.standardOutput == Data(streamAnswer.utf8))
        #expect(
            filed.standardOutput == piped.standardOutput,
            "the file held \"\(text(filed.standardOutput))\""
        )
    }
}
