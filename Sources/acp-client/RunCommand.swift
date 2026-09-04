import ArgumentParser

/// `acp-client run` — start the agent, run one turn, print the answer, and exit
/// (`cli-plan.md` §6).
///
/// This is the default subcommand, so `acp-client -- <agent-command>` runs a
/// turn without naming `run`.
struct RunCommand: AsyncParsableCommand {
    /// The name of this subcommand on the command line.
    static let name = "run"

    /// The milestone of `cli-plan.md` §15 that writes ``run()``.
    private static let milestone = "N2"

    /// The command-line configuration of `run`.
    static let configuration = CommandConfiguration(
        commandName: Self.name,
        abstract: "Starts the agent, runs one turn, prints the answer, and exits."
    )

    /// The prompt of the turn, or `nil` when the command line carried none.
    ///
    /// `nil` is not an error on its own. ``PromptSource`` reads the table of
    /// `cli-plan.md` §7, which sends a missing prompt to standard input when
    /// standard input is not a terminal.
    @Argument(
        help: ArgumentHelp(
            "The prompt of the turn.",
            discussion: """
                With no prompt, and standard input a pipe or a file, the prompt \
                comes from standard input. A prompt of \
                "\(PromptSource.standardInputArgument)" reads standard input in \
                a terminal too.
                """,
            valueName: "prompt"
        )
    )
    var prompt: String?

    /// The options of `cli-plan.md` §6.1 that every subcommand takes.
    @OptionGroup var options: SharedOptions

    /// The agent command that follows the `--` separator.
    @OptionGroup var invocation: AgentInvocation

    /// Runs one turn against the agent.
    ///
    /// - Throws: ``SubcommandNotImplementedError`` until milestone N2 of
    ///   `cli-plan.md` §15 writes the turn.
    func run() async throws {
        throw SubcommandNotImplementedError(commandName: Self.name, milestone: Self.milestone)
    }
}
