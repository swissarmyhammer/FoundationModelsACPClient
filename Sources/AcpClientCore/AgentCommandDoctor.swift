import Darwin
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
// Six rules of this file are not free choices.
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
// 4. **The capabilities row reads the RAW answer, and never the decoded one.**
//    `InitializeResponse` decodes `capabilities` and `authMethods` forgivingly:
//    a member of the wrong shape degrades to a default and throws nothing. A
//    row that read the decoded value would therefore report `ok` against every
//    agent, and a check that cannot fail is not a check. So the row takes the
//    `result` member of the answer off the frame tee, decodes it itself, and
//    compares what the agent SENT with what the decode kept. Only `info` and
//    `protocolVersion` can make that decode throw at all, and those two are
//    what the row reports as an error; every member the decode silently
//    dropped is what it reports as a warning. The `capabilities` members are
//    compared by NAME, and the `authMethods` elements by COUNT alone:
//    `AuthMethod` is the wire's own union, and this package must not spell
//    what a readable element looks like. An element the raw array held and
//    the decoded array does not is a dropped one, and the arithmetic is the
//    whole test. A `capabilities` member that is not an object, and an
//    `authMethods` member that is not an array, are each named as that
//    member, because the decode dropped the whole of it; a `null` member is
//    absent, which the schema allows, and is no loss.
// 5. **The teardown row runs BEFORE the connection closes.** Closing the
//    connection cancels the tee's forwarding task, which ends the transport's
//    byte stream, which runs `AgentProcess`'s own teardown and group-kills the
//    agent. A teardown row placed after that would report `ok` against every
//    agent, for the same reason rule 4 exists.
// 6. **The teardown row watches the process GROUP, and never the pid.**
//    `kill(pid, 0)` cannot tell a running agent from an unreaped zombie of one,
//    and an agent that leaves a child holds its own stdout open through that
//    child, so nothing reaps it. `killpg(pid, 0)` asks the question the row
//    means to ask — is anything left — and it answers for the agent, for a
//    zombie of the agent, and for a child of it, all at once.
//
// The rows below are the whole §10 table.

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

    /// The name of the sixth row: the answer this build read is the answer the
    /// agent sent.
    static let capabilitiesCheckName = "the advertised capabilities"

    /// The name of the seventh row: the agent leaves nothing behind when its
    /// stdin closes.
    static let teardownCheckName = "the agent's teardown"

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
        capabilitiesCheckName,
        teardownCheckName,
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

    /// The number of seconds ``teardownInterval`` covers.
    private static let teardownSeconds = 2

    /// How long the seventh row waits for the agent's process group to empty
    /// after the agent's stdin closes.
    ///
    /// An agent that obeys the rule ends on the EOF and needs a fraction of
    /// this, and the wait ends the moment the group empties, so the whole
    /// interval is spent only against an agent that is already leaking. Two
    /// seconds is long beside the exit of a program with nothing left to do,
    /// and short beside the patience of a person running a diagnosis.
    static let teardownInterval: Duration = .seconds(teardownSeconds)

    /// The number of seconds ``defaultTimeLimit`` covers.
    private static let defaultTimeLimitSeconds = 10

    /// The bound a doctor spends on one row when the caller states none.
    ///
    /// It belongs to the doctor alone. See rule 2 at the head of this file for
    /// why it is never the `--timeout` of `cli-plan.md` §6.1.
    static let defaultTimeLimit: Duration = .seconds(defaultTimeLimitSeconds)

    /// The terminal layer the connection behind rows three to five writes to.
    ///
    /// It writes nowhere. The doctor's REPORT is the whole output of `doctor`,
    /// and `cli-plan.md` §8 sends it to standard error, so a check that put a
    /// line of its own there would write on the report a caller is rendering.
    /// Both readings the layer takes are injected here rather than left to
    /// their defaults, so no descriptor of this process is read and none is
    /// written.
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

    /// Receives every line of the exchange the rows read, or `nil` for none.
    ///
    /// This is the seam `--frames` reaches the doctor through. The rows read
    /// the exchange off a tee of their own, and the sink of that tee feeds the
    /// two readings rows three to six rest on. A caller that wants to SEE the
    /// exchange gets each teed line here, marked with its direction, beside
    /// those two readings. It never gets it through the terminal the
    /// connection holds: that one stays silent, so that no check can write on
    /// the report a caller is rendering.
    let frameSink: FrameLineSink?

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
    ///   - frameSink: Receives each line the tee copies, marked with its
    ///     direction and without its terminator, or `nil` for none. The tee
    ///     calls it from more than one task, so it must tolerate that.
    init(
        command: String,
        arguments: [String] = [],
        resolver: AgentCommandResolver = AgentCommandResolver(),
        timeLimit: Duration = AgentCommandDoctor.defaultTimeLimit,
        frameSink: FrameLineSink? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.resolver = resolver
        self.timeLimit = timeLimit
        self.frameSink = frameSink
    }

    /// What this doctor is called in the report: the command as it was typed.
    var doctorName: String { command }

    /// The group every finding of this doctor belongs to.
    var doctorCategory: String { Self.category }

    /// Runs the seven rows of `cli-plan.md` §10 this doctor owns, in order.
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
    /// - Returns: The findings for rows two to seven, in report order.
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
        ] + (await connectedChecks(of: agent, pid: pid))
    }

    /// Runs the five rows that need the started agent's stdio, and closes the
    /// connection after.
    ///
    /// The first four share one connection because they are one exchange. See
    /// rule 3 at the head of this file for why the standard-output row reads
    /// what the `initialize` request produced rather than waiting for a line of
    /// its own, and rule 4 for why the capabilities row reads the raw answer.
    ///
    /// The connection reads the agent's stdout through a ``FrameTeeTransport``,
    /// which copies each whole line to a sink BEFORE it hands the chunk on. So
    /// every line that reached the handshake has already reached both readings,
    /// and neither needs a wait of its own. The same sink hands each line to
    /// ``frameSink``, so a caller that asked to see the exchange sees exactly
    /// the lines the readings judged.
    ///
    /// The teardown row runs before the connection closes. See rule 5.
    ///
    /// - Parameters:
    ///   - agent: The started agent, whose stdio the connection runs over.
    ///   - pid: The agent's pid, which is also its process-group id.
    /// - Returns: The findings for rows three to seven, in report order.
    @MainActor
    private func connectedChecks(of agent: AgentProcess, pid: pid_t) async -> [HealthCheck] {
        let reading = AgentStandardOutputReading()
        let answer = AgentInitializeAnswerReading()
        let frameSink = frameSink
        // The tee is bound here rather than passed inline, so it outlives the
        // exchange: `FrameTeeTransport.deinit` cancels the forwarding task that
        // copies the agent's lines.
        let tee = FrameTeeTransport(wrapping: agent.transport) { line in
            reading.record(line)
            answer.record(line)
            frameSink?(line)
        }
        let session = await AgentSession(over: tee, terminal: Self.silentTerminal, cwd: nil)
        let outcome = await initializeOutcome(of: session)
        let teardown = await Self.teardownCheck(
            of: agent,
            pid: pid,
            within: min(Self.teardownInterval, timeLimit)
        )
        await session.teardown()
        return [
            Self.standardOutputCheck(reading),
            Self.initializeCheck(outcome, within: timeLimit),
            Self.protocolVersionCheck(outcome),
            Self.capabilitiesCheck(answer.result),
            teardown,
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

    /// The finding for the sixth row: the answer this build read is the answer
    /// the agent sent.
    ///
    /// See rule 4 at the head of this file for why the row reads the raw answer
    /// and never the decoded one.
    ///
    /// The row collects one loss for each kind it can find — the `capabilities`
    /// members by name, the `authMethods` elements by count, and either member
    /// by name when it is not the object or the array the schema states — and
    /// names them all on one row, so a person repairs the agent in one pass.
    ///
    /// An agent that answered nothing at all, and one that answered a JSON-RPC
    /// error, both leave this row nothing to read. That is not a defect of its
    /// own, so the row is reported as one that did not run, which rule 1 makes
    /// a warning.
    ///
    /// - Parameter result: The `result` member of the agent's `initialize`
    ///   answer, as it reached the wire, or `nil` when no answer arrived.
    /// - Returns: The finding for the sixth row.
    private static func capabilitiesCheck(_ result: Data?) -> HealthCheck {
        guard let result else {
            return checkThatDidNotRun(named: capabilitiesCheckName, after: initializeCheckName)
        }
        let response: InitializeResponse
        do {
            response = try JSONDecoder().decode(InitializeResponse.self, from: result)
        } catch {
            return failed(
                capabilitiesCheckName,
                message: "the initialize answer cannot be read: \(error)",
                fix: """
                    Correct the member the message names. An initialize answer \
                    must carry both info and protocolVersion, and this client \
                    can do without neither.
                    """
            )
        }
        // The decode above read this `result` as a JSON object, so the members
        // are there; the empty default only keeps the read total.
        let answer = jsonMembers(of: result) ?? [:]
        let losses = [
            capabilityMembersLoss(in: answer, keeping: response.capabilities),
            authMethodsLoss(in: answer, keeping: response.authMethods),
        ].compactMap { $0 }
        guard !losses.isEmpty else {
            return passed(
                capabilitiesCheckName,
                message: """
                    every capability member and every authentication method the \
                    agent sent was read
                    """
            )
        }
        return warned(
            capabilitiesCheckName,
            message: losses.map(\.message).joined(separator: "; "),
            fix: losses.map(\.fix).joined(separator: " ")
        )
    }

    /// The `capabilities` members the agent sent and the decode did not keep,
    /// as one loss.
    ///
    /// Two shapes are a loss, as they are for `authMethods`. A member that is
    /// not an object at all — a string, a number, an array — is one the decode
    /// degrades to the empty default whole, so the client believes the agent
    /// supports no capability; the member itself is what that loss names. An
    /// object is compared member by member, and the loss names each member of
    /// it the decode dropped.
    ///
    /// - Parameters:
    ///   - answer: The members of the raw initialize answer, untyped.
    ///   - capabilities: What the decode made of that answer's `capabilities`.
    /// - Returns: The loss, naming the member or each dropped member of it, or
    ///   `nil` when the agent sent no `capabilities` member or the decode kept
    ///   every member of it.
    private static func capabilityMembersLoss(
        in answer: [String: Any],
        keeping capabilities: AgentCapabilities
    ) -> DecodeLoss? {
        guard let sent = memberTheAgentSent(named: capabilitiesKey, in: answer) else { return nil }
        guard let sentMembers = sent as? [String: Any] else { return capabilitiesShapeLoss }
        let dropped = membersTheDecodeDropped(from: sentMembers, keeping: capabilities)
        guard !dropped.isEmpty else { return nil }
        return DecodeLoss(
            message: """
                the agent sent capability members this build cannot read, and the \
                decode dropped them: \(dropped.joined(separator: ", "))
                """,
            fix: """
                Send each capability in the shape the negotiated protocol \
                version states. A member this client cannot read becomes an \
                unsupported one, so the agent loses the capability rather than \
                the handshake.
                """
        )
    }

    /// The `authMethods` the agent sent and the decode did not keep, as one
    /// loss.
    ///
    /// Two shapes are a loss. A member that is not an array at all — a string,
    /// a number, an object — is one the decode degrades to `nil` whole, so the
    /// client believes the agent advertised no method; the member itself is
    /// what that loss names, as the `capabilities` half names its member. A
    /// `null` member is not that shape: the schema lets the member be absent,
    /// and `null` is one way of writing absent, so it is no loss.
    ///
    /// For an array, the comparison is a COUNT, and never a reading of what an
    /// element looks like. `AuthMethod` is an enumeration over the wire's own
    /// union, and this package must not spell what a readable element is. The
    /// decode drops an element it cannot read and keeps the rest, so an
    /// element the raw array held and the decoded array does not is a dropped
    /// one, and the arithmetic is the whole test.
    ///
    /// - Parameters:
    ///   - answer: The members of the raw initialize answer, untyped.
    ///   - authMethods: What the decode made of that answer's `authMethods`.
    /// - Returns: The loss, naming the member or how many elements were
    ///   dropped, or `nil` when the agent sent no `authMethods` member or the
    ///   decode kept every element of it.
    private static func authMethodsLoss(
        in answer: [String: Any],
        keeping authMethods: [AuthMethod]?
    ) -> DecodeLoss? {
        guard let sent = memberTheAgentSent(named: authMethodsKey, in: answer) else { return nil }
        guard let elements = sent as? [Any] else { return authMethodsShapeLoss }
        let dropped = elements.count - (authMethods?.count ?? 0)
        guard dropped > 0 else { return nil }
        return DecodeLoss(
            message: """
                the decode dropped \(dropped) of the \(elements.count) authentication \
                methods the agent advertised, because this build cannot read them
                """,
            fix: """
                Send each authentication method in the shape the negotiated \
                protocol version states. A method this client cannot read is \
                dropped, so a person cannot log in with it.
                """
        )
    }

    /// One member of the raw answer, when the agent sent it.
    ///
    /// A `null` member is absent. The schema lets both members the sixth row
    /// reads be left out, and `null` is how an agent that writes every member
    /// spells left out, so the decode reads it as no member and the row must
    /// read it the same way rather than as a member of the wrong shape. Both
    /// halves of the row read their member here, so the two cannot disagree
    /// about what absent means.
    ///
    /// - Parameters:
    ///   - name: The member to read.
    ///   - answer: The members of the raw initialize answer, untyped.
    /// - Returns: The member's value, or `nil` when the agent left the member
    ///   out or sent `null`.
    private static func memberTheAgentSent(named name: String, in answer: [String: Any]) -> Any? {
        guard let sent = answer[name], !(sent is NSNull) else { return nil }
        return sent
    }

    /// The loss for an `authMethods` member that is not an array at all.
    private static let authMethodsShapeLoss = shapeLoss(
        of: authMethodsKey,
        expecting: "an array",
        costing: """
            A member of another shape becomes no method at all, so a person \
            cannot log in with any of them.
            """
    )

    /// The loss for a `capabilities` member that is not an object at all.
    private static let capabilitiesShapeLoss = shapeLoss(
        of: capabilitiesKey,
        expecting: "an object",
        costing: """
            A member of another shape becomes no capability at all, so the \
            client asks the agent for nothing it can do.
            """
    )

    /// The loss for a member the agent sent in a shape the schema does not
    /// state at all.
    ///
    /// The decode degrades such a member to its default whole and throws
    /// nothing, so the row names the member rather than what it held: there is
    /// nothing inside it to compare, and the whole of it is what the client
    /// lost. Both halves of the row build their shape loss here, so the two
    /// cannot drift apart in what they say.
    ///
    /// - Parameters:
    ///   - member: The name of the member, as the answer carries it.
    ///   - shape: The shape the schema states for the member, with its
    ///     article.
    ///   - cost: What the client loses when the member is dropped, as the
    ///     sentence that ends the fix.
    /// - Returns: The loss.
    private static func shapeLoss(
        of member: String,
        expecting shape: String,
        costing cost: String
    ) -> DecodeLoss {
        DecodeLoss(
            message: """
                the \(member) member the agent sent is not \(shape), and the \
                decode dropped it whole
                """,
            fix: """
                Send \(member) as \(shape), in the form the negotiated protocol \
                version states. \(cost)
                """
        )
    }

    /// The names of the members of one `capabilities` object the decode did
    /// not keep.
    ///
    /// The comparison is a round trip, and not a list of member names spelled
    /// here: the decoded capabilities are encoded again, and every key the raw
    /// object carried with a value other than `null` that the re-encoding does
    /// not carry is a member this build lost. That catches a member of the
    /// wrong shape, which `AgentCapabilities` degrades to `nil` rather than
    /// refusing, and it catches a member of a schema this build does not know.
    /// It cannot report a member the agent never sent, and it keeps no list of
    /// its own to go stale against the schema.
    ///
    /// - Parameters:
    ///   - sentMembers: The members of the raw `capabilities` object, untyped.
    ///   - capabilities: What the decode made of that object.
    /// - Returns: The names of the lost members, sorted, or an empty array.
    private static func membersTheDecodeDropped(
        from sentMembers: [String: Any],
        keeping capabilities: AgentCapabilities
    ) -> [String] {
        let read = encodedMemberNames(of: capabilities)
        return sentMembers.keys
            .filter { !(sentMembers[$0] is NSNull) && !read.contains($0) }
            .sorted()
    }

    /// The member names one `AgentCapabilities` value would send.
    ///
    /// - Parameter capabilities: The decoded capabilities.
    /// - Returns: The member names, or an empty set when the value does not
    ///   encode to a JSON object.
    private static func encodedMemberNames(of capabilities: AgentCapabilities) -> Set<String> {
        guard let encoded = try? JSONEncoder().encode(capabilities),
            let members = jsonMembers(of: encoded)
        else {
            return []
        }
        return Set(members.keys)
    }

    /// The members of one JSON object, untyped.
    ///
    /// - Parameter json: The bytes of one JSON value.
    /// - Returns: The members, or `nil` when the bytes are not a JSON object.
    private static func jsonMembers(of json: Data) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: json) else { return nil }
        return value as? [String: Any]
    }

    /// The finding for the seventh row: the agent leaves nothing behind.
    ///
    /// The row closes the agent's stdin, which is the wire's own way of saying
    /// that no more requests are coming, and then watches the agent's process
    /// GROUP. See rule 6 at the head of this file for why the group and not the
    /// pid, and rule 5 for why this row runs before the connection closes.
    ///
    /// The finding is a WARNING and never an error: such an agent answered
    /// every request, so it is usable, and it leaks. `cli-plan.md` §9 gives
    /// that verdict exit code 5, and this row is the reason that code exists.
    ///
    /// - Parameters:
    ///   - agent: The started agent, whose stdin this closes.
    ///   - pid: The agent's pid, which is also its process-group id.
    ///   - interval: The longest time to wait for the group to empty.
    /// - Returns: The finding for the seventh row.
    private static func teardownCheck(
        of agent: AgentProcess,
        pid: pid_t,
        within interval: Duration
    ) async -> HealthCheck {
        agent.closeStandardInput()
        guard await processGroupOutlived(pid, for: interval) else {
            return passed(
                teardownCheckName,
                message: "the agent ended when its stdin closed, and it left no child"
            )
        }
        return warned(
            teardownCheckName,
            message: """
                the process group of agent \(pid) still held a process \(interval) after \
                its stdin closed
                """,
            fix: """
                End the agent when its stdin reaches EOF, and end every child \
                it started before it goes. A leaked agent holds the model \
                weights it loaded.
                """
        )
    }

    /// Watches one agent's process group until it empties or the interval ends.
    ///
    /// ``AgentProcess`` spawns the agent as the leader of its own process
    /// group, so the agent's pid is that group's id and `killpg` with signal 0
    /// asks whether ANY member of it is left.
    ///
    /// - Parameters:
    ///   - pid: The agent's pid, which is also its process-group id.
    ///   - interval: The longest time to watch.
    /// - Returns: Whether the group still held a process when the watch ended.
    private static func processGroupOutlived(_ pid: pid_t, for interval: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: interval)
        while killpg(pid, 0) == 0 {
            guard clock.now < deadline else { return true }
            try? await Task.sleep(for: watchPollInterval)
        }
        return false
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

    /// One warning finding of this doctor.
    ///
    /// - Parameters:
    ///   - name: The row that found a defect short of a failure.
    ///   - message: What the row found.
    ///   - fix: The action that repairs it.
    /// - Returns: The finding, in this doctor's own group.
    private static func warned(_ name: String, message: String, fix: String) -> HealthCheck {
        .warning(name: name, message: message, fix: fix, category: category)
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

    /// The agent answered with another protocol version.
    case mismatched(ProtocolVersionMismatchError)

    /// The doctor's time limit ended before any answer arrived.
    case timeLimitReached

    /// The agent refused the handshake, or went away during it.
    case failed(any Error)
}

/// One thing the agent sent in its `initialize` answer that the forgiving
/// decode dropped.
///
/// The sixth row collects one of these for each kind of loss it can find, so
/// one row names every loss rather than the first alone.
private struct DecodeLoss {
    /// What was lost, for the row's message.
    let message: String

    /// The action that repairs it, for the row's fix.
    let fix: String
}

/// The member of an `initialize` answer that carries what the agent supports.
private let capabilitiesKey = "capabilities"

/// The member of an `initialize` answer that carries the authentication
/// methods the agent advertises.
private let authMethodsKey = "authMethods"

/// The member of a JSON-RPC answer that carries what the call produced.
private let jsonRPCResultKey = "result"

/// The agent's own text of one teed line, or `nil` for a line no reading in
/// this file may judge.
///
/// Two kinds are dropped. A line this CLIENT sent carries the outbound mark,
/// and every reading here reads the agent's standard output alone. A line the
/// tee marked incomplete is the tail of a stream that ended mid-message, which
/// says the agent died rather than that it wrote something whole.
///
/// - Parameter teedLine: One line of the exchange, as the tee marked it.
/// - Returns: The line the agent wrote, without its mark.
private func completeLineFromTheAgent(in teedLine: String) -> String? {
    guard teedLine.hasPrefix(FrameTeeTransport.inboundMark) else { return nil }
    let line = teedLine.dropFirst(FrameTeeTransport.inboundMark.count)
    guard !line.hasPrefix(FrameTeeTransport.incompleteTag) else { return nil }
    return String(line)
}

/// The `result` member of the one `initialize` answer the doctor's exchange
/// produced.
///
/// The doctor sends exactly one request, `initialize`, so the first complete
/// line the agent wrote that is a JSON object carrying a `result` member IS
/// that request's answer. A notification carries a `method` and no `result`,
/// and an agent that refused the handshake carries an `error` and no `result`,
/// so neither reaches this reading.
///
/// The reading is taken through the same ``FrameTeeTransport`` sink as
/// ``AgentStandardOutputReading``, and that sink is called from more than one
/// task, so the state stands behind a `Mutex`.
private final class AgentInitializeAnswerReading: Sendable {
    /// The `result` member of the answer, as JSON, under the lock the sink
    /// takes.
    private let answer = Mutex<Data?>(nil)

    /// The `result` member of the agent's `initialize` answer, as it reached
    /// the wire, or `nil` when no answer arrived.
    var result: Data? { answer.withLock { $0 } }

    /// Records one line the tee copied, and keeps the first answer among them.
    ///
    /// - Parameter teedLine: One line of the exchange, as the tee marked it.
    func record(_ teedLine: String) {
        guard let line = completeLineFromTheAgent(in: teedLine),
            let result = Self.resultMember(of: line)
        else {
            return
        }
        answer.withLock { recorded in
            if recorded == nil {
                recorded = result
            }
        }
    }

    /// The `result` member of one ndJSON line, as JSON of its own.
    ///
    /// - Parameter line: One complete line the agent wrote.
    /// - Returns: The member, or `nil` when the line carries none.
    private static func resultMember(of line: String) -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
            let members = message as? [String: Any],
            let result = members[jsonRPCResultKey]
        else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: result)
    }
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
        guard let line = completeLineFromTheAgent(in: teedLine) else { return }
        lines.withLock { seen in
            seen.sawALine = true
            if seen.firstLineThatIsNotJSON == nil && !Self.isJSON(line) {
                seen.firstLineThatIsNotJSON = line
            }
        }
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
