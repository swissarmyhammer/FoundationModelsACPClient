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
    /// - Throws: ``missingAgentCommand`` when the separator, or the command
    ///   after it, is missing.
    func validate() throws {
        guard !agentCommand.isEmpty else { throw Self.missingAgentCommand }
    }

    /// Returns the agent executable and the arguments that go with it.
    ///
    /// The first word names the agent and the rest are its own, in the order
    /// given. ``validate()`` has already rejected an empty list by the time the
    /// parser reaches a command body, so the failure below is that same failure
    /// said again rather than a second rule.
    ///
    /// - Returns: The agent executable, and its own arguments.
    /// - Throws: ``missingAgentCommand`` when the invocation names no agent.
    func command() throws -> AgentCommand {
        guard let executable = agentCommand.first else { throw Self.missingAgentCommand }
        return AgentCommand(executable: executable, arguments: Array(agentCommand.dropFirst()))
    }

    /// The failure ``validate()`` and ``command()`` both report for an
    /// invocation that names no agent.
    ///
    /// There is no default agent. A default would name one agent, and the
    /// no-knowledge-of-our-runtime claim of `plan.md` would stop being true.
    ///
    /// ArgumentParser turns a `ValidationError` into the usage text on stderr
    /// and the usage row of `cli-plan.md` §9.
    private static var missingAgentCommand: ValidationError {
        ValidationError(
            """
            No agent command was given. There is no default agent. \
            Name the agent after "\(Self.separator)", as in: \
            acp-client run "write a haiku" \(Self.separator) acp-agent acp
            """
        )
    }
}

/// The agent executable one subcommand starts, and the arguments that go with
/// it.
///
/// The two halves travel together because ``AgentProcess`` takes them apart:
/// the executable is resolved to an absolute path, and the arguments reach the
/// agent unchanged.
struct AgentCommand: Sendable {
    /// The agent executable, as the command line spelled it.
    ///
    /// It is a bare name, a relative path or an absolute path, and
    /// ``AgentCommandResolver`` is what turns any of the three into the
    /// absolute path ``AgentProcess`` demands.
    let executable: String

    /// The agent's own arguments, in the order given.
    let arguments: [String]
}
