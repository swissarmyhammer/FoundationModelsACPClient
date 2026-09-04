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
