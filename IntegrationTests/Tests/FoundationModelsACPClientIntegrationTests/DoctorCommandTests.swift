import Foundation
import Testing

@testable import AcpClientCore

// These tests drive the real `acp-client doctor` binary against a real foreign
// agent, and assert what `cli-plan.md` §10 and §9 promise: the report on
// stdout, and an exit code that carries the verdict.
//
// `AgentCommandDoctorTests` asserts each ROW of the check table, over the
// `Doctorable` directly. This file asserts what the SUBCOMMAND adds: the report
// reaches standard output, `--json` writes the same findings as JSON, and the
// worst finding decides the exit code. Nothing here re-asserts a row's status,
// which is that file's work.
//
// The exit codes are spelled again below rather than read from
// `AcpClientExitCode`, for the reason `ProbeCommandTests` states: a test that
// drives the binary end to end must pin §9 independently of the table the
// binary reads. The ROW NAMES are not spelled again — they come from
// `AgentCommandDoctor`, which is the one place `cli-plan.md` §10 is written as
// code, and the binary and this suite link the same library.

/// The number of minutes this file's suite allows itself.
///
/// Every test here spawns two real processes — the binary, and the agent it
/// starts — and one of them waits out the doctor's own ten-second limit. The
/// bound each test really rests on is ``doctorRunBound``; this one is the
/// backstop that ends a wedged run rather than holding the package open.
private let doctorSuiteTimeLimitMinutes = 5

/// The number of seconds ``doctorRunBound`` covers.
private let doctorRunBoundSeconds = 60

/// The longest one `acp-client doctor` run may take in this suite.
///
/// It stands well over the work the slowest test here does: a spawn, the
/// doctor's own half-second settle, and the whole of
/// ``AgentCommandDoctor/defaultTimeLimit`` spent waiting on an agent that never
/// answers. The default bound of `runAcpClient(_:)` is that same ten seconds,
/// so a doctor run that MEANS to reach its limit would be killed as a hang
/// under it.
private let doctorRunBound: Duration = .seconds(doctorRunBoundSeconds)

/// The exit code `cli-plan.md` §9 gives a doctor run whose every check passed.
private let doctorPassedExitCode: Int32 = 0

/// The exit code `cli-plan.md` §9 gives a doctor run that found an error.
private let doctorFoundAnErrorExitCode: Int32 = 1

/// The exit code `cli-plan.md` §9 gives a mistake on the command line.
///
/// It is the row code 5 exists to stay clear of: the Rust doctor exits 2 for an
/// error, and a script would then read a broken agent as a typing mistake.
private let usageErrorExitCode: Int32 = 2

/// The exit code `cli-plan.md` §9 gives a doctor run that found warnings and no
/// error.
private let doctorFoundWarningsExitCode: Int32 = 5

/// The member of a `--json` check entry that names what was checked.
private let checkNameKey = "name"

/// The member of a `--json` check entry that carries how the check went.
private let checkStatusKey = "status"

/// The member of a `--json` check entry that carries what the check found.
private let checkMessageKey = "message"

/// The member of a `--json` check entry that carries the action that repairs
/// what the check found.
private let checkFixKey = "fix"

/// The `status` value of a check that found something broken.
private let errorStatusValue = "error"

/// The `status` value of a check whose subject works.
private let okStatusValue = "ok"

/// `acp-client doctor` end to end: the report, the JSON form, and the verdict.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns real processes.
@Suite(
    "acp-client doctor reports and verdicts",
    .serialized,
    .timeLimit(.minutes(doctorSuiteTimeLimitMinutes))
)
struct DoctorCommandTests {
    /// Builds the command line of one `doctor` against a stub-agent script.
    ///
    /// The scripts carry no execute bit, so the agent command is the shell and
    /// the script is its argument, which is also the shape `cli-plan.md` §6
    /// gives an agent that takes arguments of its own.
    ///
    /// - Parameters:
    ///   - options: The options of §6.1 to put before the separator.
    ///   - script: The absolute path of the stub-agent script.
    /// - Returns: The arguments for ``runAcpClient(_:standardInput:standardOutput:environment:within:)``.
    private static func doctorArguments(options: [String] = [], script: String) -> [String] {
        [DoctorCommand.name] + options + ["--", stubAgentShellCommand, script]
    }

    /// Runs one `doctor` against a stub-agent script, and gives back its report.
    ///
    /// - Parameters:
    ///   - script: The absolute path of the stub-agent script.
    ///   - options: The options of §6.1 to put before the separator.
    /// - Returns: The finished run, and everything it wrote to standard output.
    /// - Throws: A run failure, or the bound of ``doctorRunBound``.
    private static func doctor(
        over script: String,
        options: [String] = []
    ) async throws -> (result: CLIResult, report: String) {
        let result = try await runAcpClient(
            doctorArguments(options: options, script: script),
            within: doctorRunBound
        )
        return (result, String(decoding: result.standardOutput, as: UTF8.self))
    }

    /// Reads the `--json` report of one run as a list of check entries.
    ///
    /// - Parameter result: The finished run.
    /// - Returns: One entry for each check, in report order.
    /// - Throws: A requirement failure when the bytes are not a JSON array of
    ///   objects.
    private static func checkEntries(in result: CLIResult) throws -> [[String: Any]] {
        let parsed = try JSONSerialization.jsonObject(with: result.standardOutput)
        let report = String(decoding: result.standardOutput, as: UTF8.self)
        return try #require(parsed as? [[String: Any]], "the report was \"\(report)\"")
    }

    /// Reads one member of one `--json` check entry.
    ///
    /// - Parameters:
    ///   - key: The member to read.
    ///   - entry: The check entry to read it from.
    /// - Returns: The member's text.
    /// - Throws: A requirement failure when the entry carries no such member.
    private static func text(_ key: String, of entry: [String: Any]) throws -> String {
        try #require(entry[key] as? String, "the check entry \(entry) carries no \(key)")
    }

    @Test("a well-behaved agent gets a report on stdout, nothing on stderr, and exit 0")
    func aWellBehavedAgentPassesAndExitsZero() async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let (result, report) = try await Self.doctor(over: script)

        #expect(result.exitCode == doctorPassedExitCode)
        #expect(!report.isEmpty)
        // §8 makes the doctor's REPORT its output, so stdout carries it and
        // stderr stays empty even though a check failing is what this command
        // is for.
        #expect(
            result.standardError.isEmpty,
            "stderr was \"\(String(decoding: result.standardError, as: UTF8.self))\""
        )
    }

    @Test("the plain report holds a line for every row of the check table")
    func thePlainReportHoldsEveryRowOfTheTable() async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let (_, report) = try await Self.doctor(over: script)

        for name in AgentCommandDoctor.checkNamesInOrder {
            #expect(report.contains(name), "the report holds no \(name) row: \"\(report)\"")
        }
    }

    @Test("an agent that writes a banner to stdout is reported as an error, and exits 1")
    func aBannerOnStdoutIsAnErrorAndExitsOne() async throws {
        let script = try makeBannerOnStdoutAgent()
        defer { removeAgentScript(script) }

        let (result, report) = try await Self.doctor(over: script)

        #expect(result.exitCode == doctorFoundAnErrorExitCode)
        #expect(
            report.contains(AgentCommandDoctor.standardOutputCheckName),
            "the report holds no standard-output row: \"\(report)\""
        )
        #expect(
            report.contains(stubAgentBannerLine),
            "the report did not quote the offending line: \"\(report)\""
        )
    }

    @Test("an agent that never answers reports a timeout rather than hanging, and exits 1")
    func aSilentAgentReportsATimeoutAndExitsOne() async throws {
        let script = try makeSilentAgent()
        defer { removeAgentScript(script) }

        let (result, report) = try await Self.doctor(over: script)

        // The run returned at all, inside a bound far under the suite's own
        // backstop, which is what tells a reported timeout from a hang.
        #expect(result.exitCode == doctorFoundAnErrorExitCode)
        #expect(
            report.contains("\(AgentCommandDoctor.defaultTimeLimit)"),
            "the report did not name the limit it reached: \"\(report)\""
        )
    }

    @Test("an agent that only leaks exits 5, and never 2")
    func anAgentThatOnlyLeaksExitsFive() async throws {
        let script = try makeLingeringAgent()
        defer { removeAgentScript(script) }

        let (result, report) = try await Self.doctor(over: script)

        // Such an agent answered every request, so it is usable, and it leaks.
        // §9 gives that verdict its own code so a script never reads it as the
        // usage mistake 2 stands for.
        #expect(result.exitCode == doctorFoundWarningsExitCode)
        #expect(result.exitCode != usageErrorExitCode)
        #expect(
            report.contains(AgentCommandDoctor.teardownCheckName),
            "the report holds no teardown row: \"\(report)\""
        )
    }

    @Test("an agent command that is on no PATH exits 1 and names the command")
    func anAgentCommandThatIsOnNoPathExitsOne() async throws {
        let missingCommand = "acp-client-doctor-no-such-agent-\(UUID().uuidString)"

        let result = try await runAcpClient(
            [DoctorCommand.name, "--", missingCommand],
            within: doctorRunBound
        )

        #expect(result.exitCode == doctorFoundAnErrorExitCode)
        // The command that could not be found is a FINDING of the report, and
        // not an error on stderr: the report is what a person reads to repair
        // the agent, so it has to name what was typed.
        let report = String(decoding: result.standardOutput, as: UTF8.self)
        #expect(report.contains(missingCommand), "the report was \"\(report)\"")
    }

    @Test("--json writes one entry for each check, holding its name, status and message")
    func theJSONFormHoldsOneEntryForEachCheck() async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let (result, _) = try await Self.doctor(over: script, options: ["--json"])

        #expect(result.exitCode == doctorPassedExitCode)
        let entries = try Self.checkEntries(in: result)
        var names: [String] = []
        for entry in entries {
            let status = try Self.text(checkStatusKey, of: entry)
            let message = try Self.text(checkMessageKey, of: entry)
            names.append(try Self.text(checkNameKey, of: entry))
            #expect(!status.isEmpty)
            #expect(!message.isEmpty)
        }
        #expect(names == AgentCommandDoctor.checkNamesInOrder)
    }

    @Test("every error entry of the --json report carries a non-empty fix")
    func everyErrorEntryOfTheJSONFormCarriesAFix() async throws {
        let script = try makeBannerOnStdoutAgent()
        defer { removeAgentScript(script) }

        let (result, _) = try await Self.doctor(over: script, options: ["--json"])

        var reportedAnError = false
        for entry in try Self.checkEntries(in: result) {
            let status = try Self.text(checkStatusKey, of: entry)
            if status == errorStatusValue {
                reportedAnError = true
                let fix = try Self.text(checkFixKey, of: entry)
                #expect(!fix.isEmpty, "\(entry)")
            }
        }
        // A report of errors and no fixes tells a person what is broken and
        // nothing about how to repair it, so the agent this test drives is one
        // that fails a row.
        #expect(reportedAnError, "no check of this report reported an error")
    }

    @Test("an invocation naming no agent exits 2, and writes no report")
    func anInvocationNamingNoAgentExitsTwo() async throws {
        let result = try await runAcpClient([DoctorCommand.name], within: doctorRunBound)

        // 2 and 5 are two different answers, and this is the test that holds
        // them apart: a usage mistake is not a doctor verdict.
        #expect(result.exitCode == usageErrorExitCode)
        #expect(result.standardOutput.isEmpty)
        #expect(!result.standardError.isEmpty)
    }

    @Test(
        "--timeout never becomes the doctor's own limit",
        arguments: [["--timeout", "0"], ["--timeout=-1"]]
    )
    func theTurnTimeoutNeverBecomesTheDoctorsLimit(option: [String]) async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let (result, _) = try await Self.doctor(over: script, options: option + ["--json"])

        // `--timeout` bounds the TURN of `cli-plan.md` §6.1, and `doctor` runs
        // no turn, so the doctor keeps its own limit whatever the option says.
        // A limit of zero reaching the rows would collapse both the settle
        // interval and the initialize race, and every row that rests on them
        // would report a failure this agent does not have.
        #expect(result.exitCode == doctorPassedExitCode)
        for entry in try Self.checkEntries(in: result) {
            #expect(try Self.text(checkStatusKey, of: entry) == okStatusValue, "\(entry)")
        }
    }
}
