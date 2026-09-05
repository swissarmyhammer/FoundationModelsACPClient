import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// These tests drive the real `acp-client probe` binary against a real foreign
// agent, and assert what `cli-plan.md` §6 promises: the report on stdout, no
// turn, the session closed, and no agent process left behind.
//
// Everything is asserted from OUTSIDE the run. The report comes from the pipe,
// the exit code from the process table, and what reached the agent from a
// transcript file the agent wrote itself. The `acp-client` target publishes no
// module to this package, so the exit codes and the report's own lines are
// spelled again below, against the same sections of `cli-plan.md` the unit
// suite pins the binary to. The protocol version is not spelled again: it comes
// from the library both the stub agent and the binary negotiate with, so the
// assertion cannot drift from the handshake.

/// The number of minutes this file's suite allows itself.
///
/// Every test here spawns two real processes — the binary, and the agent it
/// starts — and one of them waits out the binary's own bounded wait for a
/// command list. The bound each test really rests on is
/// ``TransportTestDeadline/limit``; this one is the backstop that ends a wedged
/// run rather than holding the package open.
private let probeSuiteTimeLimitMinutes = 5

/// The exit code `cli-plan.md` §9 gives a report that ran.
///
/// The number is spelled here rather than read from the binary's
/// `AcpClientExitCode`, which this package cannot import. The unit suite's
/// `ExitCodeTests` pins that table against the same §9 rows.
private let reportRanExitCode: Int32 = 0

/// The exit code `cli-plan.md` §9 gives a spawn or protocol error.
private let failureExitCode: Int32 = 1

/// The line the report writes for an agent that reported a command list holding
/// no command.
///
/// It is spelled here for the reason the exit codes are, and `ProbeReportTests`
/// in the unit suite pins the binary to the same text.
private let reportedNoCommandLine = "the agent reported none"

/// The line the report writes for an agent that reported no command list before
/// the bounded wait ended.
private let waitEndedFirstLine = "the agent sent no command list before the wait ended"

/// `acp-client probe` end to end: the report, the two streams, and the reap.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns real processes.
@Suite(
    "acp-client probe reports",
    .serialized,
    .timeLimit(.minutes(probeSuiteTimeLimitMinutes))
)
struct ProbeCommandTests {
    /// The text that stands before the unique part of a transcript file's name.
    private static let transcriptFileNamePrefix = "acp-client-probe-requests-"

    /// The text that stands before the unique part of a pid file's name.
    private static let pidFileNamePrefix = "acp-client-probe-agent-pid-"

    /// The text that stands before the unique part of a session working
    /// directory's name.
    private static let workingDirectoryNamePrefix = "acp-client-probe-cwd-"

    /// Runs one `probe` against a fresh stub agent, and gives back the report.
    ///
    /// - Parameters:
    ///   - commands: How the stub agent reports its slash commands.
    ///   - options: The options of §6.1 to put before the separator.
    /// - Returns: The finished run, and everything it wrote to standard output.
    /// - Throws: A script-writing failure, or a run failure.
    private static func probe(
        commands: StubAgentCommandReport = .twoCommands,
        options: [String] = []
    ) async throws -> (result: CLIResult, report: String) {
        let script = try makeProbeAgent(commands: commands)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            agentCommandArguments(probeSubcommandName, options: options, script: script)
        )
        return (result, String(decoding: result.standardOutput, as: UTF8.self))
    }

    @Test("the report names the protocol version, the capabilities, the auth methods and the commands")
    func theReportNamesEveryPartTheAgentReported() async throws {
        let (result, report) = try await Self.probe()

        #expect(result.exitCode == reportRanExitCode)
        #expect(
            report.contains("\(ACPClient.supportedProtocolVersion.rawValue)"),
            "the report was \"\(report)\""
        )
        #expect(report.contains("session"), "the report was \"\(report)\"")
        for method in stubAgentAuthMethods {
            guard case .agent(let advertised) = method else { continue }
            #expect(report.contains(advertised.methodId.rawValue), "the report was \"\(report)\"")
            #expect(report.contains(advertised.name), "the report was \"\(report)\"")
        }
        for command in stubAgentCommands {
            #expect(report.contains(command.name), "the report was \"\(report)\"")
            #expect(report.contains(command.description), "the report was \"\(report)\"")
        }
    }

    @Test("a default probe writes its report to stdout and nothing to stderr")
    func aDefaultProbeLeavesStandardErrorEmpty() async throws {
        let (result, report) = try await Self.probe()

        #expect(!report.isEmpty)
        #expect(
            result.standardError.isEmpty,
            "stderr was \"\(String(decoding: result.standardError, as: UTF8.self))\""
        )
    }

    @Test("probe sends no session/prompt, and closes the session it opened")
    func probeRunsNoTurnAndClosesItsSession() async throws {
        let transcript = temporaryFileURL(prefix: Self.transcriptFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let script = try makeProbeAgent(transcript: transcript.path)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            agentCommandArguments(probeSubcommandName, script: script)
        )

        #expect(result.exitCode == reportRanExitCode)
        let received = try String(contentsOf: transcript, encoding: .utf8)
        #expect(!received.contains("session/prompt"), "the agent read \"\(received)\"")
        #expect(received.contains("session/close"), "the agent read \"\(received)\"")
    }

    @Test("an empty command list and a wait that ended first read differently, and both exit 0")
    func theTwoEmptyCommandStatesReadDifferently() async throws {
        let (reportedNone, reportedNoneText) = try await Self.probe(commands: .emptyList)
        let (neverReported, neverReportedText) = try await Self.probe(commands: .noUpdate)

        #expect(reportedNone.exitCode == reportRanExitCode)
        #expect(neverReported.exitCode == reportRanExitCode)
        #expect(reportedNoneText != neverReportedText)
        #expect(
            reportedNoneText.contains(reportedNoCommandLine),
            "the report was \"\(reportedNoneText)\""
        )
        #expect(
            neverReportedText.contains(waitEndedFirstLine),
            "the report was \"\(neverReportedText)\""
        )
    }

    @Test("--cwd reaches the session/new request")
    func theWorkingDirectoryOptionReachesTheAgent() async throws {
        let directory = temporaryFileURL(prefix: Self.workingDirectoryNamePrefix)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = temporaryFileURL(prefix: Self.transcriptFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let script = try makeProbeAgent(transcript: transcript.path)
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            agentCommandArguments(
                probeSubcommandName,
                options: ["--cwd", directory.path],
                script: script
            )
        )

        #expect(result.exitCode == reportRanExitCode)
        let received = try String(contentsOf: transcript, encoding: .utf8)
        #expect(
            received.contains(directory.lastPathComponent),
            "the agent read \"\(received)\""
        )
    }

    @Test("--json writes valid JSON holding the four parts, and the plain form writes none")
    func theJSONFormParsesAndThePlainFormIsNotJSON() async throws {
        let (result, report) = try await Self.probe(options: ["--json"])
        let (_, plain) = try await Self.probe()

        #expect(result.exitCode == reportRanExitCode)
        let parsed = try JSONSerialization.jsonObject(with: result.standardOutput)
        let members = try #require(parsed as? [String: Any], "the report was \"\(report)\"")
        #expect(members["protocolVersion"] != nil)
        #expect(members["capabilities"] != nil)
        #expect(members["authMethods"] != nil)
        #expect(members["slashCommands"] != nil)
        #expect(!plain.contains("{"), "the plain report was \"\(plain)\"")
    }

    @Test("an agent command that is not on PATH exits 1, says so on stderr, and writes no report")
    func anAgentCommandThatIsNotOnPathFails() async throws {
        let missingCommand = "acp-client-no-such-agent-\(UUID().uuidString)"

        let result = try await runAcpClient(["probe", "--", missingCommand])

        #expect(result.exitCode == failureExitCode)
        #expect(result.standardOutput.isEmpty)
        let reported = String(decoding: result.standardError, as: UTF8.self)
        #expect(reported.contains(missingCommand), "stderr was \"\(reported)\"")
    }

    @Test("an agent that refuses initialize exits 1 and writes no report")
    func anAgentThatRefusesInitializeFails() async throws {
        let script = try makeInitializeRefusingAgent()
        defer { removeAgentScript(script) }

        let result = try await runAcpClient(
            agentCommandArguments(probeSubcommandName, script: script)
        )

        #expect(result.exitCode == failureExitCode)
        #expect(result.standardOutput.isEmpty)
        #expect(!result.standardError.isEmpty)
    }

    @Test("no agent process outlives the probe", arguments: [true, false])
    func noAgentProcessOutlivesTheProbe(initializes: Bool) async throws {
        let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script =
            initializes
            ? try makeProbeAgent(pidFile: pidFile.path)
            : try makeInitializeRefusingAgent(pidFile: pidFile.path)
        defer { removeAgentScript(script) }

        _ = try await runAcpClient(agentCommandArguments(probeSubcommandName, script: script))

        let pid = try recordedAgentPid(in: pidFile)
        #expect(!processExists(pid), "the agent with pid \(pid) outlived the probe")
    }
}
