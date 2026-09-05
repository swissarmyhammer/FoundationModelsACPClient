import ArgumentParser

/// The options of `cli-plan.md` §6.1 that every subcommand takes.
///
/// `--json` is not here. §6.1 gives it to `probe` and `doctor` alone, so it
/// lives in ``ReportOptions``, which `run` does not embed. Holding it here
/// would make `acp-client run --json` parse, and a run has no report to write.
struct SharedOptions: ParsableArguments {
    /// The working directory of the session, or `nil` for the working
    /// directory of this process.
    @Option(
        help: ArgumentHelp(
            "The working directory of the session.",
            discussion: "Defaults to the working directory of this process.",
            valueName: "path"
        )
    )
    var cwd: String?

    /// Whether to write every ndJSON message to stderr, in both directions.
    ///
    /// `cli-plan.md` §6.1 calls this the reason the binary exists: it shows the
    /// protocol exchange, so a person can see what an agent sent.
    @Flag(
        help: "Write every ndJSON message to stderr, in both directions, with a direction mark."
    )
    var frames = false

    /// The limit on the turn, in seconds, or `nil` for no limit.
    @Option(
        help: ArgumentHelp(
            "End the run if the turn does not stop in time.",
            discussion: "Defaults to no limit.",
            valueName: "seconds"
        )
    )
    var timeout: Double?

    /// Whether to write the session events to stderr, one line each.
    @Flag(help: "Write the session events to stderr.")
    var verbose = false

    /// Whether to draw no progress and no decoration, in a terminal too.
    @Flag(help: "Draw no progress and no decoration, in a terminal too.")
    var quiet = false

    /// The limit ``timeout`` states as a `Duration`, or `nil` for no limit.
    ///
    /// It is the TURN's limit, and never a diagnosis's own. ``AgentCommandDoctor``
    /// bounds each of its rows with a limit of its own, for the reason rule 2 at
    /// the head of that file states, and the two never share a value.
    var turnLimit: Duration? {
        timeout.map { .seconds($0) }
    }

    /// Rejects a `--timeout` value the turn cannot run in.
    ///
    /// ArgumentParser calls this on the group of every subcommand that embeds
    /// it, and it reads what this throws as a validation failure, which
    /// ``AcpClient/processExitCode(for:)`` turns into the usage row of
    /// `cli-plan.md` §9. So one check here holds for `run`, `probe` and
    /// `doctor` alike: a limit that gives the turn no time at all is a mistake
    /// on the command line whichever subcommand it was typed after.
    ///
    /// - Throws: `ValidationError` when `--timeout` is not more than zero
    ///   seconds.
    mutating func validate() throws {
        guard let timeout else { return }
        guard timeout > 0 else {
            throw ValidationError(
                """
                The --timeout value must be more than zero seconds. \
                \(timeout) gives the turn no time to run in.
                """
            )
        }
    }
}

/// The `--json` option of `cli-plan.md` §6.1, which `probe` and `doctor` take
/// and `run` does not.
///
/// It is a group of one because the two report subcommands must agree on the
/// flag, and because `run` must not carry it. A single option in a single place
/// is what keeps both halves of that true.
struct ReportOptions: ParsableArguments {
    /// Whether to write the report to stdout as JSON rather than as text.
    @Flag(help: "Write the report to stdout as JSON.")
    var json = false
}
