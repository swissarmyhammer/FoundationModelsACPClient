import Foundation
import FoundationModelsExtras
import Testing

@testable import AcpClientCore

// These tests drive the real `acp-client doctor` binary against a real foreign
// agent, and assert what `cli-plan.md` §10, §9 and §8 promise: the human report
// on stderr, the `--json` report on stdout, and an exit code that carries the
// verdict.
//
// `AgentCommandDoctorTests` asserts each ROW of the check table, over the
// `Doctorable` directly. This file asserts what the SUBCOMMAND adds: the human
// report reaches standard error and leaves standard output empty, `--json`
// writes the same findings as JSON to standard output and leaves standard error
// empty, `--frames` puts the handshake on standard error ahead of the report
// and changes the report not at all, and the worst finding decides the exit
// code. Nothing here re-asserts a row's status, which is that file's work.
//
// Every stream of a run in this suite is a pipe, so the human report the binary
// writes is the plain rendering of `FoundationModelsExtras`, and never Noora's
// table: `cli-plan.md` §5 draws the table on a terminal alone, and a test
// process cannot make the binary's standard error a terminal. The terminal path
// is proven over a buffer in the unit suite, `TerminalOutputTests`.
//
// The exit codes are spelled again below rather than read from
// `AcpClientExitCode`, for the reason `ProbeCommandTests` states: a test that
// drives the binary end to end must pin §9 independently of the table the
// binary reads. The ROW NAMES are not spelled again — they come from
// `AgentCommandDoctor`, which is the one place `cli-plan.md` §10 is written as
// code, and the binary and this suite link the same library.
//
// `FoundationModelsExtras` is imported for `DoctorReport` and
// `PlainTextDoctorRenderer`. The test that decodes the `--json` form draws the
// decoded checks through the same renderer the binary uses, so the comparison
// is that renderer's own bytes and not a second drawing written here.

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

/// The option of `cli-plan.md` §6.1 that asks for the report as JSON.
private let jsonOptionName = "--json"

/// The option of `cli-plan.md` §6.1 that puts the exchange on standard error.
private let framesOptionName = "--frames"

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

/// The `method` member of the one request `doctor` sends, as it stands on the
/// wire.
///
/// A `--frames` run must show it under `FrameTeeTransport.outboundMark`. The
/// doctor sends `initialize` and nothing else, so that request is the whole
/// handshake a person asked to see.
private let initializeMethodMember = #""method":"initialize""#

/// The text that stands in for the agent's pid when two reports are compared.
///
/// The process row names the pid of the agent that run started. Two runs start
/// two agents, so the pid is the one part of the report that changes from run
/// to run while the report stays the same.
private let agentPidPlaceholder = "<pid>"

/// The byte that opens every ANSI escape sequence.
///
/// A renderer that colors a row, or that moves the cursor, writes a sequence
/// that opens with this byte. A pipe or a file must receive none of them: the
/// report a script reads has to be the same bytes every time, so a test can
/// compare it byte for byte. Every stream of a run in this suite is a pipe, so
/// one occurrence of this byte on either stream is a decorated report that
/// reached a destination that is not a terminal.
private let escapeByte: UInt8 = 0x1B

/// The two forms `doctor` writes, and the stream `cli-plan.md` §8 gives each.
///
/// The human form goes to standard error, because a report a person reads is a
/// diagnostic, and the `--json` form goes to standard output, because a script
/// reads it. A test names the form it reads, and the form names the stream, so
/// no test reads a descriptor by habit.
private enum ReportForm {
    /// The human report, on standard error.
    case plain

    /// The `--json` report, on standard output.
    case json

    /// The option that asks for this form, or nothing for the default form.
    var options: [String] {
        switch self {
        case .plain: []
        case .json: [jsonOptionName]
        }
    }

    /// The report of one finished run, read off the stream this form goes to.
    ///
    /// - Parameter result: The finished run.
    /// - Returns: The bytes of that stream, as text.
    func report(in result: CLIResult) -> String {
        switch self {
        case .plain: text(result.standardError)
        case .json: text(result.standardOutput)
        }
    }

    /// The bytes of the stream this form does NOT go to, which §8 keeps empty.
    ///
    /// - Parameter result: The finished run.
    /// - Returns: The bytes of the other stream.
    func otherStream(in result: CLIResult) -> Data {
        switch self {
        case .plain: result.standardOutput
        case .json: result.standardError
        }
    }
}

/// The lines of one human report, with the teed frames set aside.
///
/// `--frames` puts each teed line on standard error too, ahead of the report
/// and under its direction mark. The lines that carry no mark are the report,
/// so this is what two runs are compared on when one of them carried the flag.
///
/// - Parameter report: The text of standard error.
/// - Returns: The lines that carry no direction mark.
private func reportLines(of report: String) -> [String] {
    lines(of: Data(report.utf8)).filter { line in
        !line.hasPrefix(FrameTeeTransport.outboundMark)
            && !line.hasPrefix(FrameTeeTransport.inboundMark)
    }
}

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
    /// The text that stands before the unique part of a pid file's name.
    private static let pidFileNamePrefix = "acp-client-doctor-frames-agent-pid-"

    /// Runs one `doctor` against a stub-agent script, and gives back its report.
    ///
    /// - Parameters:
    ///   - script: The absolute path of the stub-agent script.
    ///   - form: The form to ask for, which is also the stream the report is
    ///     read off.
    ///   - options: The other options of §6.1 to put before the separator.
    /// - Returns: The finished run, and the report on the stream of `form`.
    /// - Throws: A run failure, or the bound of ``doctorRunBound``.
    private static func doctor(
        over script: String,
        as form: ReportForm,
        options: [String] = []
    ) async throws -> (result: CLIResult, report: String) {
        let result = try await runAcpClient(
            agentCommandArguments(
                doctorSubcommandName,
                options: options + form.options,
                script: script
            ),
            within: doctorRunBound
        )
        return (result, form.report(in: result))
    }

    /// Reads the `--json` report of one run as a list of check entries.
    ///
    /// - Parameter result: The finished run.
    /// - Returns: One entry for each check, in report order.
    /// - Throws: A requirement failure when the bytes are not a JSON array of
    ///   objects.
    private static func checkEntries(in result: CLIResult) throws -> [[String: Any]] {
        let parsed = try JSONSerialization.jsonObject(with: result.standardOutput)
        let report = ReportForm.json.report(in: result)
        return try #require(parsed as? [[String: Any]], "the report was \"\(report)\"")
    }

    /// Reads one member of one `--json` check entry.
    ///
    /// - Parameters:
    ///   - key: The member to read.
    ///   - entry: The check entry to read it from.
    /// - Returns: The member's text.
    /// - Throws: A requirement failure when the entry carries no such member.
    private static func member(_ key: String, of entry: [String: Any]) throws -> String {
        try #require(entry[key] as? String, "the check entry \(entry) carries no \(key)")
    }

    /// Runs one `doctor` over a well-behaved agent that records its pid, and
    /// gives back the report with that pid replaced by ``agentPidPlaceholder``.
    ///
    /// Each call writes its own script and its own pid file, because the stub
    /// writes the file whole and a second run over the same script would
    /// replace the first pid.
    ///
    /// - Parameters:
    ///   - form: The form to ask for, which is also the stream the report is
    ///     read off.
    ///   - options: The other options of §6.1 to put before the separator.
    /// - Returns: The finished run, and its report with the pid replaced.
    /// - Throws: A run failure, the bound of ``doctorRunBound``, or a
    ///   requirement failure when the report does not name the pid at all.
    private static func doctorReportWithoutAgentPid(
        as form: ReportForm,
        options: [String] = []
    ) async throws -> (result: CLIResult, report: String) {
        let pidFile = temporaryFileURL(prefix: pidFileNamePrefix)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try makeWellBehavedAgent(pidFile: pidFile.path)
        defer { removeAgentScript(script) }

        let (result, report) = try await doctor(over: script, as: form, options: options)

        // The replacement means something only when the report names the
        // pid, so a report that does not is a failure of this helper.
        let pid = "\(try recordedAgentPid(in: pidFile))"
        try #require(report.contains(pid), "the report names no pid: \"\(report)\"")
        return (result, report.replacingOccurrences(of: pid, with: agentPidPlaceholder))
    }

    @Test(
        "each form of the report goes to its own stream, and the other stream stays empty",
        arguments: [ReportForm.plain, .json]
    )
    fileprivate func eachFormGoesToItsOwnStreamAlone(form: ReportForm) async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let (result, report) = try await Self.doctor(over: script, as: form)

        #expect(result.exitCode == doctorPassedExitCode)
        #expect(!report.isEmpty)
        // §8 sends the human report to stderr, because a person reads it as a
        // diagnostic, and the `--json` form to stdout, because a script reads
        // it as data. Each form leaves the other stream empty, so a script
        // that reads one stream never meets the other form.
        let other = form.otherStream(in: result)
        #expect(other.isEmpty, "the other stream held \"\(text(other))\"")
    }

    @Test("the plain report holds a line for every row of the check table")
    func thePlainReportHoldsEveryRowOfTheTable() async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let (_, report) = try await Self.doctor(over: script, as: .plain)

        for name in AgentCommandDoctor.checkNamesInOrder {
            #expect(report.contains(name), "the report holds no \(name) row: \"\(report)\"")
        }
    }

    @Test("--frames writes the marked initialize request and answer to standard error, beside the report")
    func framesWritesTheHandshakeToStandardError() async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let (result, report) = try await Self.doctor(
            over: script,
            as: .plain,
            options: [framesOptionName]
        )

        #expect(result.exitCode == doctorPassedExitCode)
        let reported = lines(of: result.standardError)
        let outbound = reported.filter { $0.hasPrefix(FrameTeeTransport.outboundMark) }
        let inbound = reported.filter { $0.hasPrefix(FrameTeeTransport.inboundMark) }
        #expect(
            outbound.contains { $0.contains(initializeMethodMember) },
            "no outbound line carried the initialize request: \(reported)"
        )
        #expect(
            inbound.contains { $0.contains(stubAgentName) },
            "no inbound line carried the initialize answer: \(reported)"
        )
        // The frames are the one thing the flag adds, and the report still
        // stands on the same stream beside them: every row is among the lines
        // that carry no direction mark, and stdout stays empty.
        let unmarked = reportLines(of: report)
        for name in AgentCommandDoctor.checkNamesInOrder {
            #expect(unmarked.contains { $0.contains(name) }, "no report line names \(name): \(unmarked)")
        }
        #expect(result.standardOutput.isEmpty, "stdout held \"\(text(result.standardOutput))\"")
    }

    @Test("the report is the same with --frames and without, apart from the pid")
    func framesLeavesTheReportUnchanged() async throws {
        let plain = try await Self.doctorReportWithoutAgentPid(as: .plain)
        let framed = try await Self.doctorReportWithoutAgentPid(
            as: .plain,
            options: [framesOptionName]
        )

        #expect(plain.result.exitCode == doctorPassedExitCode)
        #expect(framed.result.exitCode == doctorPassedExitCode)
        // Line equality of the unmarked lines is what pins "the frames change
        // the report not at all": one teed line that lost its mark, or one
        // report line moved or reworded, fails this.
        #expect(
            reportLines(of: framed.report) == reportLines(of: plain.report),
            "the --frames report was \"\(framed.report)\", the plain report \"\(plain.report)\""
        )
    }

    @Test("an agent that writes a banner to stdout is reported as an error, and exits 1")
    func aBannerOnStdoutIsAnErrorAndExitsOne() async throws {
        let script = try makeBannerOnStdoutAgent()
        defer { removeAgentScript(script) }

        let (result, report) = try await Self.doctor(over: script, as: .plain)

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

        let (result, report) = try await Self.doctor(over: script, as: .plain)

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

        let (result, report) = try await Self.doctor(over: script, as: .plain)

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
        // not a bare error line: the report is what a person reads to repair
        // the agent, so it has to name what was typed.
        let report = ReportForm.plain.report(in: result)
        #expect(report.contains(missingCommand), "the report was \"\(report)\"")
    }

    @Test("--json writes one entry for each check, holding its name, status and message")
    func theJSONFormHoldsOneEntryForEachCheck() async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let (result, _) = try await Self.doctor(over: script, as: .json)

        #expect(result.exitCode == doctorPassedExitCode)
        let entries = try Self.checkEntries(in: result)
        var names: [String] = []
        for entry in entries {
            let status = try Self.member(checkStatusKey, of: entry)
            let message = try Self.member(checkMessageKey, of: entry)
            names.append(try Self.member(checkNameKey, of: entry))
            #expect(!status.isEmpty)
            #expect(!message.isEmpty)
        }
        #expect(names == AgentCommandDoctor.checkNamesInOrder)
    }

    @Test("every error entry of the --json report carries a non-empty fix")
    func everyErrorEntryOfTheJSONFormCarriesAFix() async throws {
        let script = try makeBannerOnStdoutAgent()
        defer { removeAgentScript(script) }

        let (result, _) = try await Self.doctor(over: script, as: .json)

        var reportedAnError = false
        for entry in try Self.checkEntries(in: result) {
            let status = try Self.member(checkStatusKey, of: entry)
            if status == errorStatusValue {
                reportedAnError = true
                let fix = try Self.member(checkFixKey, of: entry)
                #expect(!fix.isEmpty, "\(entry)")
            }
        }
        // A report of errors and no fixes tells a person what is broken and
        // nothing about how to repair it, so the agent this test drives is one
        // that fails a row.
        #expect(reportedAnError, "no check of this report reported an error")
    }

    @Test("--json decodes to the checks the plain report draws")
    func theJSONFormDecodesToTheChecksThePlainReportDraws() async throws {
        let plain = try await Self.doctorReportWithoutAgentPid(as: .plain)
        let encoded = try await Self.doctorReportWithoutAgentPid(as: .json)

        #expect(plain.result.exitCode == doctorPassedExitCode)
        #expect(encoded.result.exitCode == doctorPassedExitCode)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: Data(encoded.report.utf8))
        #expect(decoded.checks.map(\.name) == AgentCommandDoctor.checkNamesInOrder)
        // The plain report is the renderer's own drawing of the checks the
        // binary found, so drawing the decoded checks through that renderer
        // again must give the plain run's bytes. One entry dropped, one status
        // changed, or one message reworded on either form fails this.
        #expect(
            PlainTextDoctorRenderer().render(decoded) == plain.report,
            "the decoded --json report was \"\(encoded.report)\", the plain report \"\(plain.report)\""
        )
    }

    @Test("a report written to a pipe holds no ANSI escape on either stream")
    func aReportWrittenToAPipeHoldsNoEscape() async throws {
        let script = try makeBannerOnStdoutAgent()
        defer { removeAgentScript(script) }

        let (result, report) = try await Self.doctor(over: script, as: .plain)

        // The banner agent fails a row, so this report holds passing rows, an
        // error row and a fix line: every row a decorated table would color.
        // Both streams of the run are pipes, and neither may carry an escape.
        #expect(result.exitCode == doctorFoundAnErrorExitCode)
        #expect(
            !result.standardError.contains(escapeByte),
            "stderr carried an escape: \"\(report)\""
        )
        #expect(
            !result.standardOutput.contains(escapeByte),
            "stdout carried an escape: \"\(text(result.standardOutput))\""
        )
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
        arguments: [
            timeoutOption(collapsingTimeoutValue),
            ["\(timeoutOptionName)=\(collapsingTimeoutValue)"],
        ]
    )
    func theTurnTimeoutNeverBecomesTheDoctorsLimit(option: [String]) async throws {
        let script = try makeWellBehavedAgent()
        defer { removeAgentScript(script) }

        let (result, _) = try await Self.doctor(over: script, as: .json, options: option)

        // `--timeout` bounds the TURN of `cli-plan.md` §6.1, and `doctor` runs
        // no turn, so the doctor keeps its own limit whatever the option says.
        // A limit of one millisecond reaching the rows would collapse both the
        // initialize race and the teardown watch, and every row that rests on
        // them would report a failure this agent does not have.
        #expect(result.exitCode == doctorPassedExitCode)
        for entry in try Self.checkEntries(in: result) {
            #expect(try Self.member(checkStatusKey, of: entry) == okStatusValue, "\(entry)")
        }
    }
}
