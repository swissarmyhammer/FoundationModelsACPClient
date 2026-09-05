import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import FoundationModelsExtras
import Synchronization

// `AgentCommandDoctor` — the one `Doctorable` this package writes, over one
// foreign agent command (`cli-plan.md` §10).
//
// The protocol, the runner, the report and the plain renderer all come from
// `FoundationModelsExtras`. This package writes no doctor framework: it writes
// the checks, because it is the only part that knows what an ACP agent is.
//
// Three rules of this file are not free choices.
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
// 3. **The standard-output row reads what `initialize` produced, and never
//    what it hopes will arrive.** A conformant ACP agent writes to stdout only
//    in ANSWER to a request, so a check that read stdout and waited for a line
//    would wait for ever against a CORRECT agent. The §10 table splits "it
//    writes valid ndJSON, and nothing else" from "`initialize` answers inside a
//    time limit" as two rows, and they are two rows here, but they are ONE
//    exchange: the doctor sends `initialize`, waits out the limit at most, and
//    then judges every whole line the agent wrote while that ran. A banner on
//    stdout — the defect §10 calls the most common one — stands ahead of the
//    answer in that reading, so the row still catches it.
//
// The rows below are the first five of the §10 table. The two after them read
// the capabilities and the teardown, and they belong to the following task.

/// Reports whether one foreign agent command is usable (`cli-plan.md` §10).
///
/// The value holds the agent command as the person typed it, so a report names
/// what they wrote rather than what it resolved to. ``runHealthChecks()``
/// resolves the command, starts the agent, and runs one `initialize` exchange
/// over it, and it reports every row whichever way the earlier ones went.
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

    /// The name of the third row: standard output carries ndJSON, and nothing
    /// else.
    static let standardOutputCheckName = "the agent's standard output"

    /// The name of the fourth row: `initialize` answers inside the time limit.
    static let initializeCheckName = "the initialize answer"

    /// The name of the fifth row: the agent answered with the version that was
    /// sent.
    static let protocolVersionCheckName = "the protocol version"

    /// Every row this doctor reports, in the order the report carries them.
    ///
    /// The order is the content, and it is also what
    /// ``checksThatDidNotRun(after:)`` reads: each row rests on the ones before
    /// it, so a failure names every row it took down with it.
    static let checkNamesInOrder = [
        commandCheckName,
        processCheckName,
        standardOutputCheckName,
        initializeCheckName,
        protocolVersionCheckName,
    ]

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

    /// The terminal layer the connection behind rows three to five writes to.
    ///
    /// It writes nowhere. `cli-plan.md` §8 makes the doctor's REPORT its
    /// output, so a check that put a line of its own on standard error would
    /// break the report a caller is rendering. Both readings the layer takes
    /// are injected here rather than left to their defaults, so no descriptor
    /// of this process is read and none is written.
    private static let silentTerminal = TerminalOutput(
        verbosity: .quiet,
        isStandardErrorATerminal: { false },
        sink: { _ in }
    )

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

    /// Runs the five rows of `cli-plan.md` §10 this doctor owns, in order.
    ///
    /// Each row rests on the ones before it: a command that resolves to nothing
    /// cannot be started, and an agent that never started answers nothing. Each
    /// is reported all the same — see rule 1 at the head of this file.
    ///
    /// - Returns: One finding for each row, the command row first.
    func runHealthChecks() async -> [HealthCheck] {
        let executable: String
        do {
            executable = try resolver.resolve(command)
        } catch {
            return [
                Self.failed(
                    Self.commandCheckName,
                    message: String(describing: error),
                    fix: Self.fix(for: error)
                )
            ] + Self.checksThatDidNotRun(after: Self.commandCheckName)
        }
        return [
            Self.passed(
                Self.commandCheckName,
                message: "the command resolves to \(executable)"
            )
        ] + (await startedAgentChecks(for: executable))
    }

    /// Starts the agent, runs every row that needs it, and reaps it whichever
    /// way those rows went.
    ///
    /// The watch is what tells a working agent from one whose runtime is
    /// missing. ``AgentProcess`` reaps the child when the child's stdout
    /// reaches EOF, so an agent that died clears its own pid, while an agent
    /// that blocks on its stdin — which is what a conformant ACP agent does
    /// while it waits for `initialize` — keeps it.
    ///
    /// - Parameter executable: The absolute path the first row resolved.
    /// - Returns: The findings for rows two to five, in report order.
    private func startedAgentChecks(for executable: String) async -> [HealthCheck] {
        let agent: AgentProcess
        do {
            agent = try AgentProcess(command: executable, arguments: arguments)
        } catch {
            return [
                Self.failed(
                    Self.processCheckName,
                    message: String(describing: error),
                    fix: "Check that \(executable) is a program this machine can run."
                )
            ] + Self.checksThatDidNotRun(after: Self.processCheckName)
        }
        // `cli-plan.md` §11 lets no agent outlive the command that started it,
        // and a diagnosis is no exception: the teardown stands on every path
        // out of this function, the failing ones included.
        defer { agent.shutdown() }

        await Self.watch(agent, for: min(Self.settleInterval, timeLimit))
        guard let pid = agent.processIdentifier else {
            return [
                Self.failed(
                    Self.processCheckName,
                    message: "the agent went away as soon as it started",
                    fix: """
                        Run the agent command in a shell and read what it says. \
                        A missing runtime, or a crash on start, is the usual reason.
                        """
                )
            ] + Self.checksThatDidNotRun(after: Self.processCheckName)
        }
        return [
            Self.passed(
                Self.processCheckName,
                message: "the agent started and stayed, as process \(pid)"
            )
        ] + (await connectedChecks(over: agent.transport))
    }

    /// Runs the three rows that need a live connection, and closes it after.
    ///
    /// The three share one connection because they are one exchange. See rule 3
    /// at the head of this file for why the standard-output row reads what the
    /// `initialize` request produced rather than waiting for a line of its own.
    ///
    /// The connection reads the agent's stdout through a ``FrameTeeTransport``,
    /// which copies each whole line to a sink BEFORE it hands the chunk on. So
    /// every line that reached the handshake has already reached the reading,
    /// and the reading needs no wait of its own.
    ///
    /// - Parameter transport: The started agent's stdio.
    /// - Returns: The findings for rows three to five, in report order.
    @MainActor
    private func connectedChecks(over transport: any ACPTransport) async -> [HealthCheck] {
        let reading = AgentStandardOutputReading()
        // The tee is bound here rather than passed inline, so it outlives the
        // exchange: `FrameTeeTransport.deinit` cancels the forwarding task that
        // copies the agent's lines.
        let tee = FrameTeeTransport(wrapping: transport) { line in reading.record(line) }
        let session = await AgentSession(over: tee, terminal: Self.silentTerminal, cwd: nil)
        let outcome = await initializeOutcome(of: session)
        await session.teardown()
        return [
            Self.standardOutputCheck(reading),
            Self.initializeCheck(outcome, within: timeLimit),
            Self.protocolVersionCheck(outcome),
        ]
    }

    /// Races one `initialize` against the doctor's time limit.
    ///
    /// The limit CANCELS the request rather than abandoning it. `Connection`
    /// wraps each call in a task-cancellation handler and fails the pending
    /// request at once, so the call below always returns and no task is left
    /// running behind the report. That is what makes the fourth row report a
    /// timeout instead of becoming one.
    ///
    /// Nothing but the limit cancels the handshake, so a `CancellationError` IS
    /// the limit having ended first.
    ///
    /// - Parameter session: The connected agent.
    /// - Returns: What the exchange came back with.
    @MainActor
    private func initializeOutcome(of session: AgentSession) async -> InitializeOutcome {
        let limit = timeLimit
        let handshake = Task { @MainActor in try await session.initialize() }
        let limiter = Task {
            try await Task.sleep(for: limit)
            handshake.cancel()
        }
        defer { limiter.cancel() }
        do {
            return .answered(try await handshake.value)
        } catch let mismatch as ProtocolVersionMismatchError {
            return .mismatched(mismatch)
        } catch is CancellationError {
            return .timeLimitReached
        } catch {
            return .failed(error)
        }
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

    /// The finding for the third row: standard output carries ndJSON, and
    /// nothing else.
    ///
    /// An agent that wrote no whole line at all leaves this row nothing to
    /// judge, and that is not a defect of its own: a conformant agent writes
    /// only in answer to a request, so the cause is always the `initialize`
    /// exchange that came back with nothing. The row is reported as one that
    /// did not run, which rule 1 at the head of this file makes a warning.
    ///
    /// - Parameter reading: What the agent wrote while the handshake ran.
    /// - Returns: The finding for the third row.
    private static func standardOutputCheck(
        _ reading: AgentStandardOutputReading
    ) -> HealthCheck {
        guard reading.sawALine else {
            return checkThatDidNotRun(named: standardOutputCheckName, after: initializeCheckName)
        }
        guard let offending = reading.firstLineThatIsNotJSON else {
            return passed(
                standardOutputCheckName,
                message: "every line the agent wrote to stdout is valid JSON"
            )
        }
        // A line the agent wrote is judged whichever way the handshake then
        // went, so this row reads the reading alone.
        return failed(
            standardOutputCheckName,
            message: "the agent wrote a line to stdout that is not JSON: \(offending)",
            fix: """
                Send the banner, the log line and every other diagnostic to \
                standard error. An ACP agent writes ndJSON to standard output \
                and nothing else.
                """
        )
    }

    /// The finding for the fourth row: `initialize` answered inside the limit.
    ///
    /// A version mismatch is an ANSWER, and it arrived in time, so this row
    /// passes for it and the fifth row carries that failure alone.
    ///
    /// - Parameters:
    ///   - outcome: What the handshake came back with.
    ///   - limit: The bound the handshake was raced against.
    /// - Returns: The finding for the fourth row.
    private static func initializeCheck(
        _ outcome: InitializeOutcome,
        within limit: Duration
    ) -> HealthCheck {
        switch outcome {
        case .answered(let response):
            return passed(
                initializeCheckName,
                message: "\(response.info.name) \(response.info.version) answered initialize"
            )
        case .mismatched(let mismatch):
            return passed(
                initializeCheckName,
                message: """
                    the agent answered initialize, reporting protocol version \
                    \(mismatch.received.rawValue)
                    """
            )
        case .timeLimitReached:
            return failed(
                initializeCheckName,
                message: "the agent did not answer initialize inside \(limit)",
                fix: """
                    Read the agent's own standard error while it starts. An \
                    agent that never answers initialize is usually waiting on \
                    something of its own.
                    """
            )
        case .failed(let error):
            return failed(
                initializeCheckName,
                message: "initialize was not answered: \(error)",
                fix: "Read the agent's own standard error, and correct what it reports."
            )
        }
    }

    /// The finding for the fifth row: the agent answered with the version that
    /// was sent.
    ///
    /// The message names BOTH versions, because "a v1 agent, or a newer draft"
    /// is actionable only when the report says which version each side spoke.
    ///
    /// - Parameter outcome: What the handshake came back with.
    /// - Returns: The finding for the fifth row.
    private static func protocolVersionCheck(_ outcome: InitializeOutcome) -> HealthCheck {
        switch outcome {
        case .answered(let response):
            return passed(
                protocolVersionCheckName,
                message: "the agent answered protocol version \(response.protocolVersion.rawValue)"
            )
        case .mismatched(let mismatch):
            return failed(
                protocolVersionCheckName,
                message: """
                    this client sent protocol version \(mismatch.sent.rawValue), and the \
                    agent answered protocol version \(mismatch.received.rawValue)
                    """,
                fix: """
                    Run an agent that speaks ACP protocol version \
                    \(mismatch.sent.rawValue). This client speaks that version alone.
                    """
            )
        case .timeLimitReached, .failed:
            return checkThatDidNotRun(named: protocolVersionCheckName, after: initializeCheckName)
        }
    }

    /// One passing finding of this doctor.
    ///
    /// - Parameters:
    ///   - name: The row that passed.
    ///   - message: What the row found.
    /// - Returns: The finding, in this doctor's own group.
    private static func passed(_ name: String, message: String) -> HealthCheck {
        .ok(name: name, message: message, category: category)
    }

    /// One failing finding of this doctor.
    ///
    /// - Parameters:
    ///   - name: The row that failed.
    ///   - message: What the row found.
    ///   - fix: The action that repairs it.
    /// - Returns: The finding, in this doctor's own group.
    private static func failed(_ name: String, message: String, fix: String) -> HealthCheck {
        .error(name: name, message: message, fix: fix, category: category)
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

    /// The findings for every row standing after `earlier`, none of which ran.
    ///
    /// See rule 1 at the head of this file for why each is a warning.
    ///
    /// - Parameter earlier: The row whose failure made the rest meaningless.
    /// - Returns: One warning for each later row, in report order.
    private static func checksThatDidNotRun(after earlier: String) -> [HealthCheck] {
        checkNamesInOrder
            .drop { $0 != earlier }
            .dropFirst()
            .map { checkThatDidNotRun(named: $0, after: earlier) }
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

/// What one `initialize` exchange came back with.
///
/// A version mismatch is its own case rather than one more failure, because the
/// two rows that read this value disagree about it: the agent DID answer, and
/// it answered in time, so the fourth row passes while the fifth row fails.
private enum InitializeOutcome {
    /// The agent answered, with the protocol version that was sent.
    case answered(InitializeResponse)

    /// The agent answered with an other protocol version.
    case mismatched(ProtocolVersionMismatchError)

    /// The doctor's time limit ended before any answer arrived.
    case timeLimitReached

    /// The agent refused the handshake, or went away during it.
    case failed(any Error)
}

/// What one agent wrote to its standard output while the handshake ran.
///
/// The reading is taken through a ``FrameTeeTransport`` sink, which is the one
/// place a whole line of the exchange is visible without draining the transport
/// the connection needs. The sink is called from the tee's forwarding task and
/// from the connection's own writes, so the state stands behind a `Mutex`.
private final class AgentStandardOutputReading: Sendable {
    /// What the reading has seen so far.
    private struct Lines {
        /// Whether any complete line from the agent reached the reading.
        var sawALine = false

        /// The first complete line from the agent that is not JSON.
        var firstLineThatIsNotJSON: String?
    }

    /// The lines seen so far, under the lock the sink takes.
    private let lines = Mutex(Lines())

    /// Whether any complete line from the agent reached this reading.
    var sawALine: Bool { lines.withLock { $0.sawALine } }

    /// The first complete line the agent wrote that is not JSON, or `nil` when
    /// every line it wrote is JSON.
    var firstLineThatIsNotJSON: String? { lines.withLock { $0.firstLineThatIsNotJSON } }

    /// Records one line the tee copied, and judges the ones this row owns.
    ///
    /// - Parameter teedLine: One line of the exchange, as the tee marked it.
    func record(_ teedLine: String) {
        guard let line = Self.completeLineFromTheAgent(in: teedLine) else { return }
        lines.withLock { seen in
            seen.sawALine = true
            if seen.firstLineThatIsNotJSON == nil && !Self.isJSON(line) {
                seen.firstLineThatIsNotJSON = line
            }
        }
    }

    /// The agent's own text of one teed line, or `nil` for a line this row may
    /// not judge.
    ///
    /// Two kinds are dropped. A line this CLIENT sent carries the outbound
    /// mark, and this row reads the agent's standard output alone. A line the
    /// tee marked incomplete is the tail of a stream that ended mid-message,
    /// which says the agent died rather than that it wrote something that is
    /// not ndJSON.
    ///
    /// - Parameter teedLine: One line of the exchange, as the tee marked it.
    /// - Returns: The line the agent wrote, without its mark.
    private static func completeLineFromTheAgent(in teedLine: String) -> String? {
        guard teedLine.hasPrefix(FrameTeeTransport.inboundMark) else { return nil }
        let line = teedLine.dropFirst(FrameTeeTransport.inboundMark.count)
        guard !line.hasPrefix(FrameTeeTransport.incompleteTag) else { return nil }
        return String(line)
    }

    /// Whether one line of the agent's standard output parses as JSON.
    ///
    /// `JSONSerialization` refuses a top-level fragment by default, and every
    /// ACP message is a JSON object, so the default is the strictness this row
    /// wants: a banner line, a log line and a bare number each fail it.
    ///
    /// - Parameter line: One complete line the agent wrote.
    /// - Returns: Whether the line is JSON.
    private static func isJSON(_ line: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil
    }
}
