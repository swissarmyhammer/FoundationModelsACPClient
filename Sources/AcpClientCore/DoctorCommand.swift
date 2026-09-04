import ArgumentParser

/// `acp-client doctor` — say whether the agent is usable (`cli-plan.md` §6 and
/// §10).
///
/// Unlike `probe`, the exit code carries the verdict: 0 when every check
/// passed, 5 when only warnings stand, and 1 when a check failed
/// (`cli-plan.md` §9).
struct DoctorCommand: AsyncParsableCommand {
    /// The name of this subcommand on the command line.
    static let name = "doctor"

    /// The milestone of `cli-plan.md` §15 that writes ``run()``.
    private static let milestone = "N5"

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

    /// Runs the checks of `cli-plan.md` §10 and prints the report.
    ///
    /// - Throws: ``SubcommandNotImplementedError`` until milestone N5 of
    ///   `cli-plan.md` §15 writes the checks.
    func run() async throws {
        throw SubcommandNotImplementedError(commandName: Self.name, milestone: Self.milestone)
    }
}
