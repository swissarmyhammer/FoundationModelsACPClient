import ArgumentParser

/// The agent command that follows the `--` separator (`cli-plan.md` §6).
///
/// `run`, `probe` and `doctor` each embed this group, so the three share one
/// grammar rather than three that drift apart.
///
/// The binary never splits a command string into words. The shell has already
/// split the command line, and re-splitting is where a quoting rule goes
/// wrong. So the agent command arrives as a list of words that the parser hands
/// over unchanged, with the agent's own flags among them.
struct AgentInvocation: ParsableArguments {
    /// The separator the grammar requires before the agent command.
    ///
    /// ArgumentParser owns the separator itself; this constant is the spelling
    /// the help text and the usage error show.
    static let separator = "--"

    /// The agent command, and its own arguments, in the order given.
    ///
    /// The default is the empty list rather than a required value, so that a
    /// missing agent command reaches ``validate()`` and gets the message §6
    /// asks for, instead of the parser's generic "missing expected argument".
    @Argument(
        parsing: .postTerminator,
        help: ArgumentHelp(
            "The agent command, and its own arguments.",
            discussion: """
                Everything after \(AgentInvocation.separator) is the agent \
                command. It reaches the agent unchanged, its own flags included.
                """,
            valueName: "agent-command"
        )
    )
    var agentCommand: [String] = []

    /// Rejects an invocation that names no agent.
    ///
    /// There is no default agent. A default would name one agent, and the
    /// no-knowledge-of-our-runtime claim of `plan.md` would stop being true.
    ///
    /// - Throws: `ValidationError` when the separator, or the command after it,
    ///   is missing. ArgumentParser turns that into the usage text on stderr
    ///   and exit code 2, which is the usage row of `cli-plan.md` §9.
    func validate() throws {
        guard !agentCommand.isEmpty else {
            throw ValidationError(
                """
                No agent command was given. There is no default agent. \
                Name the agent after "\(Self.separator)", as in: \
                acp-client run "write a haiku" \(Self.separator) acp-agent acp
                """
            )
        }
    }
}
