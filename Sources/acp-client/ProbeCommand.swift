import ArgumentParser

/// `acp-client probe` — say what the agent supports, and run no turn
/// (`cli-plan.md` §6).
///
/// `probe` and `doctor` answer two different questions. `probe` says what the
/// agent supports, and it always exits 0 when the agent answers. `doctor` says
/// whether the agent is usable, and its exit code carries the verdict.
struct ProbeCommand: AsyncParsableCommand {
    /// The name of this subcommand on the command line.
    static let name = "probe"

    /// The milestone of `cli-plan.md` §15 that writes ``run()``.
    private static let milestone = "N4"

    /// The command-line configuration of `probe`.
    static let configuration = CommandConfiguration(
        commandName: Self.name,
        abstract: """
            Starts the agent, initializes, and prints what it reports: the \
            protocol version, the agent capabilities, the authentication \
            methods, and the slash commands. Runs no turn.
            """
    )

    /// The options of `cli-plan.md` §6.1 that every subcommand takes.
    @OptionGroup var options: SharedOptions

    /// The `--json` option, which `run` does not take.
    @OptionGroup var report: ReportOptions

    /// The agent command that follows the `--` separator.
    @OptionGroup var invocation: AgentInvocation

    /// Initializes the agent and prints what it reports.
    ///
    /// - Throws: ``SubcommandNotImplementedError`` until milestone N4 of
    ///   `cli-plan.md` §15 writes the report.
    func run() async throws {
        throw SubcommandNotImplementedError(commandName: Self.name, milestone: Self.milestone)
    }
}
