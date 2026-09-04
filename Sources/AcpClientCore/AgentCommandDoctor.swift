import Foundation
import FoundationModelsACPClient
import FoundationModelsExtras

// `AgentCommandDoctor` — the one `Doctorable` this package writes, over one
// foreign agent command (`cli-plan.md` §10).
//
// The protocol, the runner, the report and the plain renderer all come from
// `FoundationModelsExtras`. This package writes no doctor framework: it writes
// the checks, because it is the only part that knows what an ACP agent is.
//
// Two rules of this file are not free choices.
//
// 1. **A check that could not run is reported, not dropped.** `HealthStatus`
//    states three levels — ok, warning, error — and no "skipped" among them.
//    So a row that did not run is a `warning` naming the row to repair first.
//    The report then keeps the same shape whatever went wrong, which is what
//    lets a person compare two runs row by row. §9 ranks an error above a
//    warning, so a run that skipped a row because an earlier one failed still
//    carries the failure's own exit code.
// 2. **The time limit here is the doctor's own.** It is never the `--timeout`
//    of §6.1: that option bounds the TURN a person asked for, and this one
//    bounds a diagnosis the person asked for instead. One value standing for
//    both would make a patient run mean a slow doctor.
//
// The rows below are the first two of the §10 table. The five after them all
// need a live ACP connection, and they belong to the two following tasks.

/// Reports whether one foreign agent command is usable (`cli-plan.md` §10).
///
/// The value holds the agent command as the person typed it, so a report names
/// what they wrote rather than what it resolved to. ``runHealthChecks()``
/// resolves the command first and starts the agent second, and it reports both
/// rows whichever way the first one went.
struct AgentCommandDoctor: Doctorable {
    /// The group every finding of this doctor belongs to.
    ///
    /// One constant, and not one group per row: the rows all answer the same
    /// question about the same subject, and a report that split them would ask
    /// a reader to hold two headings for one agent.
    static let category = "agent"

    /// The name of the first row: the command resolves to an executable.
    static let commandCheckName = "the agent command"

    /// The name of the second row: the agent starts, and it stays.
    static let processCheckName = "the agent process"

    /// The number of milliseconds ``settleInterval`` covers.
    private static let settleMilliseconds = 500

    /// How long a started agent is watched before it counts as one that stayed.
    ///
    /// Half a second is long beside the spawn it follows, and short beside the
    /// patience a person running a diagnosis has. It is also far longer than
    /// the moment an agent whose runtime is missing needs to die: that agent
    /// closes its stdout at once, the watch below ends early, and the row
    /// reports the failure without spending the rest of the interval.
    static let settleInterval: Duration = .milliseconds(settleMilliseconds)

    /// The number of milliseconds between two readings of the agent's pid.
    private static let watchPollMilliseconds = 20

    /// The pause between two readings of the agent's pid.
    private static let watchPollInterval: Duration = .milliseconds(watchPollMilliseconds)

    /// The number of seconds ``defaultTimeLimit`` covers.
    private static let defaultTimeLimitSeconds = 10

    /// The bound a doctor spends on one row when the caller states none.
    ///
    /// It belongs to the doctor alone. See rule 2 at the head of this file for
    /// why it is never the `--timeout` of `cli-plan.md` §6.1.
    static let defaultTimeLimit: Duration = .seconds(defaultTimeLimitSeconds)

    /// The agent command, as the command line spelled it.
    let command: String

    /// The agent's own arguments, in the order given.
    let arguments: [String]

    /// The lookup that turns ``command`` into an absolute executable path.
    let resolver: AgentCommandResolver

    /// The longest time one row of this doctor may take.
    let timeLimit: Duration

    /// Creates a doctor over one agent command.
    ///
    /// - Parameters:
    ///   - command: The agent command, as the command line spelled it.
    ///   - arguments: The agent's own arguments, in the order given.
    ///   - resolver: The lookup that resolves `command`. The default searches
    ///     this process's own `PATH`, which is the `PATH` the person typed the
    ///     command into.
    ///   - timeLimit: The longest time one row may take. The default is
    ///     ``defaultTimeLimit``.
    init(
        command: String,
        arguments: [String] = [],
        resolver: AgentCommandResolver = AgentCommandResolver(),
        timeLimit: Duration = AgentCommandDoctor.defaultTimeLimit
    ) {
        self.command = command
        self.arguments = arguments
        self.resolver = resolver
        self.timeLimit = timeLimit
    }

    /// What this doctor is called in the report: the command as it was typed.
    var doctorName: String { command }

    /// The group every finding of this doctor belongs to.
    var doctorCategory: String { Self.category }

    /// Runs the two rows of `cli-plan.md` §10 this doctor owns, in order.
    ///
    /// The second row rests on the first: a command that resolves to nothing
    /// cannot be started, so there is nothing for the second row to measure.
    /// It is reported all the same — see rule 1 at the head of this file.
    ///
    /// - Returns: One finding for each row, the command row first.
    func runHealthChecks() async -> [HealthCheck] {
        let executable: String
        do {
            executable = try resolver.resolve(command)
        } catch {
            return [
                .error(
                    name: Self.commandCheckName,
                    message: String(describing: error),
                    fix: Self.fix(for: error),
                    category: Self.category
                ),
                Self.checkThatDidNotRun(named: Self.processCheckName, after: Self.commandCheckName),
            ]
        }
        return [
            .ok(
                name: Self.commandCheckName,
                message: "the command resolves to \(executable)",
                category: Self.category
            ),
            await startedAgentCheck(for: executable),
        ]
    }

    /// Starts the agent, watches it, and reaps it whichever way the row went.
    ///
    /// The watch is what tells a working agent from one whose runtime is
    /// missing. ``AgentProcess`` reaps the child when the child's stdout
    /// reaches EOF, so an agent that died clears its own pid, while an agent
    /// that blocks on its stdin — which is what a conformant ACP agent does
    /// while it waits for `initialize` — keeps it.
    ///
    /// - Parameter executable: The absolute path the first row resolved.
    /// - Returns: The finding for the second row.
    private func startedAgentCheck(for executable: String) async -> HealthCheck {
        let agent: AgentProcess
        do {
            agent = try AgentProcess(command: executable, arguments: arguments)
        } catch {
            return .error(
                name: Self.processCheckName,
                message: String(describing: error),
                fix: "Check that \(executable) is a program this machine can run.",
                category: Self.category
            )
        }
        // `cli-plan.md` §11 lets no agent outlive the command that started it,
        // and a diagnosis is no exception: the teardown stands on every path
        // out of this function, the failing ones included.
        defer { agent.shutdown() }

        await Self.watch(agent, for: min(Self.settleInterval, timeLimit))
        guard let pid = agent.processIdentifier else {
            return .error(
                name: Self.processCheckName,
                message: "the agent went away as soon as it started",
                fix: """
                    Run the agent command in a shell and read what it says. \
                    A missing runtime, or a crash on start, is the usual reason.
                    """,
                category: Self.category
            )
        }
        return .ok(
            name: Self.processCheckName,
            message: "the agent started and stayed, as process \(pid)",
            category: Self.category
        )
    }

    /// Watches one started agent until it goes away or the interval ends.
    ///
    /// - Parameters:
    ///   - agent: The started agent to watch.
    ///   - interval: The longest time to watch.
    private static func watch(_ agent: AgentProcess, for interval: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: interval)
        while agent.processIdentifier != nil && clock.now < deadline {
            try? await Task.sleep(for: watchPollInterval)
        }
    }

    /// The action that repairs one resolution failure.
    ///
    /// Each case gets its own text because each is a different mistake: a name
    /// spelled wrong, a path that points at nothing, a file carrying no
    /// executable bit, and a directory named where a program belongs. The
    /// message of the finding already says what was found; this says what to
    /// do about it.
    ///
    /// - Parameter failure: What the resolution reported.
    /// - Returns: The action to take.
    private static func fix(for failure: AgentCommandResolutionFailure) -> String {
        switch failure {
        case .notFoundOnPath:
            return "Correct the spelling, or put the directory holding the agent on PATH."
        case .noSuchFile:
            return "Correct the path, or build the agent if it was never built."
        case .notExecutable:
            return "Give the file the executable bit with chmod."
        case .notARegularFile:
            return "Name the agent program itself, and not the directory holding it."
        }
    }

    /// The finding for a row that could not run because an earlier row failed.
    ///
    /// See rule 1 at the head of this file for why this is a warning.
    ///
    /// - Parameters:
    ///   - name: The row that did not run.
    ///   - earlier: The row whose failure made it meaningless.
    /// - Returns: A warning naming the row to repair first.
    private static func checkThatDidNotRun(named name: String, after earlier: String) -> HealthCheck
    {
        .warning(
            name: name,
            message: "this check did not run, because \(earlier) failed",
            fix: "Repair \(earlier), then ask the doctor again.",
            category: category
        )
    }
}
