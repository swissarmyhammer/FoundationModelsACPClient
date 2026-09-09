import ArgumentParser
import Foundation
import FoundationModelsExtras

// `DoctorCommand` — the subcommand of `cli-plan.md` §6 that says whether an
// agent is usable, and carries the verdict in its exit code.
//
// The checks are not here. `AgentCommandDoctor` owns the seven rows of §10, and
// `FoundationModelsExtras` owns the runner, the report and the renderer. What
// this file owns is the three things a SUBCOMMAND adds: the report reaches
// standard output, `--json` writes the same findings as JSON, and the worst
// finding becomes the exit code.
//
// Four decisions here are not free choices.
//
// 1. **The report goes to stdout, and the doctor writes nothing of its own to
//    stderr.** §8 keeps stdout for the answer text alone and then names `probe`
//    and `doctor` as its exceptions: their report IS their output. `run` and
//    `probe` each put a line on stderr when they fail, because a failure ends
//    those commands with no output of their own. A doctor has no such failure:
//    `runHealthChecks()` does not throw, and every defect it meets — a command
//    that resolves to nothing included — becomes a ROW of the report. A second
//    copy on stderr would say what the report already says. The one thing that
//    reaches stderr is the exchange itself, under `--frames` (decision 4), and
//    those are the agent's words and this client's, not the doctor's.
// 2. **The exit code comes from ``AcpClientExitCode/forDoctorStatus(_:)``, and
//    never from `DoctorReport.exitCode`.** The two answer the same three
//    numbers today. They are still two tables: the Extras one is that library's
//    own convention, and §9 is this binary's, which also has to hold `refusal`,
//    `cancelled`, a timeout and a usage error apart. Reading the §9 table here
//    is what keeps every outcome of this binary in one place.
// 3. **`--timeout` never reaches the doctor.** See ``doctor(for:frameSink:)``.
// 4. **The §6.1 option group is declared, and one option of it shapes the
//    diagnosis.** §6.1 gives those options to every subcommand, so `doctor`
//    has to PARSE them or the grammar of the three subcommands would differ.
//    What each one shapes is another matter. `--frames` shapes this one: it is
//    the reason the binary exists, and the defect §10 catches best — an agent
//    that writes a banner to stdout — is the one a person then wants to SEE
//    on the wire. `AgentCommandDoctor` owns the tee its rows read, so the flag
//    reaches it through ``frameSink(frames:)``: a sink the doctor calls for
//    each teed line, beside the two readings its rows rest on, and nothing
//    when the flag is absent. The other four shape nothing here: `--cwd` names
//    the working directory of a SESSION, and the rows open none — they send
//    one `initialize` and stop; `--quiet` and `--verbose` shape standard
//    error, where decision 1 lets nothing but those frames through; and
//    `--timeout` is decision 3.

/// What closes the JSON form of the report.
///
/// The plain renderer ends every line it draws, so only the JSON form needs
/// this: a report a script reads is then one ndJSON record, which is the shape
/// ``ProbeCommand`` writes too.
private let reportTerminator = "\n"

/// `acp-client doctor` — say whether the agent is usable (`cli-plan.md` §6 and
/// §10).
///
/// Unlike `probe`, the exit code carries the verdict: 0 when every check
/// passed, 5 when only warnings stand, and 1 when a check failed
/// (`cli-plan.md` §9).
struct DoctorCommand: AsyncParsableCommand {
    /// The name of this subcommand on the command line.
    static let name = "doctor"

    /// The command-line configuration of `doctor`.
    static let configuration = CommandConfiguration(
        commandName: Self.name,
        abstract: """
            Checks that this agent works: the command exists, it starts, \
            initialize answers, and the version matches.
            """
    )

    /// The options of `cli-plan.md` §6.1 that every subcommand takes.
    @OptionGroup var options: SharedOptions

    /// The `--json` option, which `run` does not take.
    @OptionGroup var report: ReportOptions

    /// The agent command that follows the `--` separator.
    @OptionGroup var invocation: AgentInvocation

    /// Runs the checks of `cli-plan.md` §10, writes the report to standard
    /// output, and exits with the verdict.
    ///
    /// - Throws: `ValidationError` for an invocation naming no agent, which
    ///   ArgumentParser turns into the usage text on stderr and the usage row of
    ///   `cli-plan.md` §9; or an `ExitCode` carrying the verdict of §9, for a
    ///   report that is not wholly `ok`.
    func run() async throws {
        let agent = try invocation.command()
        let doctor = Self.doctor(for: agent, frameSink: Self.frameSink(frames: options.frames))
        let findings = await DoctorRunner(components: [doctor]).run()
        try Self.write(findings, asJSON: report.json)

        // §9 and not `DoctorReport.exitCode`: see decision 2 at the head of this
        // file. Code 5 is the row that needs the reason said out loud. The Rust
        // doctor exits 2 for an error, and 2 is already the usage error here, so
        // a script would read a broken agent as a typing mistake.
        // `doctor-plan.md` §5 moved the warning verdict to 5 to keep the two
        // apart, and nothing here may "simplify" it back.
        let verdict = AcpClientExitCode.forDoctorStatus(findings.worstStatus)
        guard verdict != .success else { return }
        throw verdict.parserExitCode
    }

    /// Builds the doctor for one agent command.
    ///
    /// The doctor keeps ITS OWN time limit, and the `--timeout` of
    /// `cli-plan.md` §6.1 never reaches it. That option bounds the TURN a
    /// person asked for, and `doctor` runs no turn; rule 2 at the head of
    /// `AgentCommandDoctor.swift` records the decision. So the limit that
    /// bounds each row is a constant of the doctor rather than a number off the
    /// command line, and it can be neither zero nor negative — a limit of zero
    /// would collapse the settle interval and the initialize race alike, and
    /// every row resting on them would report a defect the agent does not have.
    ///
    /// - Parameters:
    ///   - agent: The agent executable and its own arguments.
    ///   - frameSink: Where each line of the exchange goes, or `nil` for a run
    ///     that asked for no frames. See ``frameSink(frames:)``.
    /// - Returns: The doctor over that command.
    private static func doctor(
        for agent: AgentCommand,
        frameSink: FrameLineSink?
    ) -> AgentCommandDoctor {
        AgentCommandDoctor(
            command: agent.executable,
            arguments: agent.arguments,
            frameSink: frameSink
        )
    }

    /// The sink `--frames` hands the doctor, or `nil` when the command line
    /// carried no flag.
    ///
    /// The sink writes through ``TerminalOutput/frame(_:)``, for the reason
    /// ``RunCommand/sessionTransport(over:frames:terminal:)`` gives: `--frames`
    /// is a debugging switch and not a verbosity level, so that member writes
    /// at every verbosity and whether or not stderr is a terminal. The layer is
    /// built at `.quiet`, because the doctor writes the frames through it and
    /// nothing else — decision 4 at the head of this file — and `frame(_:)`
    /// reads no verbosity at all. Without the flag no layer is built, so a
    /// default run pays nothing for a switch it did not ask for.
    ///
    /// - Parameter frames: Whether the command line carried `--frames`.
    /// - Returns: The sink, or `nil` for a run that asked for no frames.
    private static func frameSink(frames: Bool) -> FrameLineSink? {
        guard frames else { return nil }
        let terminal = TerminalOutput(verbosity: .quiet)
        return { terminal.frame($0) }
    }

    /// Writes one report to standard output.
    ///
    /// `cli-plan.md` §8 makes `doctor` an exception to its own stdout rule,
    /// because the report IS the output of this subcommand.
    ///
    /// The plain form comes from `PlainTextDoctorRenderer`, which draws ASCII
    /// and no terminal escape whatever the destination is — so a terminal, a
    /// pipe and a file each receive the same bytes, and a test can compare the
    /// report byte for byte. The JSON form is one line, for the reason
    /// ``ProbeCommand`` gives: a report a script reads is one ndJSON record.
    ///
    /// - Parameters:
    ///   - findings: What the checks found.
    ///   - json: Whether the command line carried `--json`.
    /// - Throws: The encoding failure of the JSON form, or the write failure of
    ///   standard output.
    private static func write(_ findings: DoctorReport, asJSON json: Bool) throws {
        guard json else {
            try PlainTextDoctorRenderer().write(findings, to: .standardOutput)
            return
        }
        let encoded = try findings.jsonData()
        try FileHandle.standardOutput.write(contentsOf: encoded + Data(reportTerminator.utf8))
    }
}
