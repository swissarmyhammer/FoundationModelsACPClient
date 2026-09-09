import ArgumentParser
import Foundation
import FoundationModelsACP
import FoundationModelsACPClient

// `ProbeCommand` — the subcommand of `cli-plan.md` §6 that says what an agent
// supports, and runs no turn.
//
// The shape follows `RunCommand`, and for the same reasons: the spawn, the reap
// and the exit code are the only things a real run adds, and the reap is a
// `defer` because §11 lets no agent outlive the command. The transport comes
// from ``RunCommand/sessionTransport(over:frames:terminal:)``, so `--frames`
// tees the same way for both subcommands and this file holds no second copy of
// it.
//
// Three decisions here are not free choices.
//
// 1. **The report goes to stdout.** §8 keeps stdout for the answer text alone
//    and then names `probe` as its one exception: its report IS its output.
//    The human `doctor` report goes to stderr instead, and only `--json` puts
//    a doctor report on stdout. Nothing else this file writes can reach stdout.
// 2. **A session opens, and no prompt is sent.** The slash commands are in
//    neither the `initialize` answer nor the `session/new` answer. In v2 they
//    arrive as an `available_commands_update` session update, so the only way
//    to read them is to open a session and wait. The session closes again, and
//    the agent is never prompted.
// 3. **The commands are read off the observable container, not off the update
//    stream.** `SessionUpdateRouter` drops an update for a session with no
//    active subscriber, and the subscription cannot exist before the
//    `session/new` answer names the session — so an agent that reports its
//    commands right after that answer reaches the router first, and the stream
//    misses the update. The container has no such gate: the connection calls
//    the client for every notification it decodes.
//
// One name to watch. `FoundationModelsACP` exports a `TerminalOutput` of its
// own — the ACP model of what an agent-owned terminal printed. Inside this
// target the local type wins the lookup, and the local type is the one this
// file means.

/// `acp-client probe` — say what the agent supports, and run no turn
/// (`cli-plan.md` §6).
///
/// `probe` and `doctor` answer two different questions. `probe` says what the
/// agent supports, and it always exits 0 when the agent answers. `doctor` says
/// whether the agent is usable, and its exit code carries the verdict.
struct ProbeCommand: AsyncParsableCommand {
    /// The name of this subcommand on the command line.
    static let name = "probe"

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

    /// The number of milliseconds `probe` waits for the agent's command list.
    ///
    /// The list arrives as an `available_commands_update` whenever the agent
    /// decides to send it, and an agent that sends none is a normal agent. So
    /// the wait is bounded, and a wait that ended first is reported as itself
    /// rather than as an empty list: ``ProbeSlashCommands/waitEndedFirst``.
    ///
    /// Two seconds is long beside the exchange that precedes it — a spawn, an
    /// `initialize` and a `session/new` — and short beside the patience a person
    /// running a report has.
    private static let commandWaitMilliseconds = 2_000

    /// The bounded wait for the agent's command list.
    private static let commandWait: Duration = .milliseconds(commandWaitMilliseconds)

    /// The number of milliseconds between two readings of the command list.
    private static let commandPollMilliseconds = 20

    /// The pause between two readings of the command list.
    ///
    /// The pause is far shorter than ``commandWait``, so a list that arrives
    /// early ends the wait early, and it is long enough that the wait costs
    /// nothing measurable.
    private static let commandPollInterval: Duration = .milliseconds(commandPollMilliseconds)

    /// Starts the agent, reads what it reports, and writes the report to
    /// standard output.
    ///
    /// - Throws: `ValidationError` for an invocation naming no agent, which
    ///   ArgumentParser turns into the usage text on stderr and the usage row of
    ///   `cli-plan.md` §9; or an `ExitCode` carrying the row of §9 the outcome
    ///   owes.
    func run() async throws {
        let terminal = TerminalOutput(
            verbosity: TerminalVerbosity(quiet: options.quiet, verbose: options.verbose)
        )
        let agent = try invocation.command()

        do {
            let probed = try await Self.probeAgent(
                agent: agent,
                cwd: options.cwd,
                frames: options.frames,
                terminal: terminal
            )
            try Self.write(probed, asJSON: report.json)
        } catch {
            // Every failure gets one line on stderr. §8 leaves a default run
            // silent there UNTIL it fails, and a run that failed without a word
            // is a run nobody can debug.
            terminal.error(String(describing: error))
            throw AcpClientExitCode.forError(error).parserExitCode
        }
    }

    /// Starts the agent, reads its report, and reaps it on every path.
    ///
    /// - Parameters:
    ///   - agent: The agent executable and its own arguments.
    ///   - cwd: The `--cwd` value, or `nil` for the process working directory.
    ///   - frames: Whether the command line carried `--frames`.
    ///   - terminal: The layer that owns standard error.
    /// - Returns: What the agent reported.
    /// - Throws: ``AgentCommandResolutionFailure`` when the command resolves to
    ///   no executable, `AgentProcessError` when the spawn fails, or whatever
    ///   the handshake itself threw.
    private static func probeAgent(
        agent: AgentCommand,
        cwd: String?,
        frames: Bool,
        terminal: TerminalOutput
    ) async throws -> ProbeReport {
        let executable = try AgentCommandResolver().resolve(agent.executable)
        let process = try AgentProcess(command: executable, arguments: agent.arguments)
        defer { process.shutdown() }
        terminal.event("the agent started: \(executable)")
        // The tee is bound here rather than passed inline, so it outlives the
        // exchange: `FrameTeeTransport.deinit` cancels the forwarding task that
        // copies the agent's lines, and a value the caller dropped would stop
        // teeing in the middle of the handshake.
        let transport = RunCommand.sessionTransport(
            over: process.transport,
            frames: frames,
            terminal: terminal
        )
        return try await readReport(over: transport, cwd: cwd, terminal: terminal)
    }

    /// Connects to the started agent, reads its report, and closes the
    /// connection on every path.
    ///
    /// A `defer` cannot `await`, so the outcome is held either way and the one
    /// teardown runs on the single path that follows.
    ///
    /// - Parameters:
    ///   - transport: The started agent's stdio.
    ///   - cwd: The `--cwd` value, or `nil` for the process working directory.
    ///   - terminal: The layer that owns standard error.
    /// - Returns: What the agent reported.
    /// - Throws: `ProtocolVersionMismatchError` when the agent answered
    ///   `initialize` with another version, ``ProcessWorkingDirectoryError``
    ///   when `--cwd` is absent and this process has no working directory,
    ///   `RequestError` on a peer error, or `ConnectionError` when the agent
    ///   went away.
    @MainActor
    private static func readReport(
        over transport: any ACPTransport,
        cwd: String?,
        terminal: TerminalOutput
    ) async throws -> ProbeReport {
        let session = await AgentSession(over: transport, terminal: terminal, cwd: cwd)
        let report: Result<ProbeReport, any Error>
        do {
            report = .success(try await buildReport(with: session))
        } catch {
            report = .failure(error)
        }
        await session.teardown()
        return try report.get()
    }

    /// Runs the handshake, opens and closes one session, and builds the report.
    ///
    /// No prompt is sent. The session exists for the command list alone, which
    /// reaches a client as a session update and nowhere else.
    ///
    /// - Parameter session: The connected agent.
    /// - Returns: What the agent reported.
    /// - Throws: Whatever ``AgentSession/initialize()`` or
    ///   ``AgentSession/openSession()`` threw.
    @MainActor
    private static func buildReport(with session: AgentSession) async throws -> ProbeReport {
        let initialized = try await session.initialize()
        // The update stream is not read. Decision 3 at the head of this file
        // states why: the container sees every update, and the stream can miss
        // the one this report needs.
        let (sessionId, _) = try await session.openSession()
        let commands = await slashCommands(in: session.container, for: sessionId)
        await session.closeSession(sessionId)
        return ProbeReport(
            protocolVersion: initialized.protocolVersion,
            capabilities: initialized.capabilities,
            // An omitted list and an empty list say the same thing on the wire:
            // the agent advertises no authentication method.
            authMethods: initialized.authMethods ?? [],
            slashCommands: commands
        )
    }

    /// Waits a bounded interval for the agent's command list, and reads it off
    /// the observable container.
    ///
    /// ``ACPSessionState/hasReportedAvailableCommands`` is what makes the three
    /// states of `cli-plan.md` §6 tellable apart: an agent that reported an
    /// empty list and an agent that reported nothing both leave
    /// ``ACPSessionState/availableCommands`` empty, and only that member says
    /// which of the two happened.
    ///
    /// - Parameters:
    ///   - container: The observable container behind the connection.
    ///   - sessionId: The session the agent opened.
    /// - Returns: The commands, or the reason there are none to report.
    @MainActor
    private static func slashCommands(
        in container: SwiftUIACPClient,
        for sessionId: SessionId
    ) async -> ProbeSlashCommands {
        let state = container.session(for: sessionId)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: commandWait)
        while !state.hasReportedAvailableCommands && clock.now < deadline {
            try? await Task.sleep(for: commandPollInterval)
        }
        guard state.hasReportedAvailableCommands else { return .waitEndedFirst }
        return .reported(state.availableCommands)
    }

    /// Writes one report to standard output.
    ///
    /// `cli-plan.md` §8 makes `probe` an exception to its own stdout rule,
    /// because the report IS the output of this subcommand. The text ends with
    /// one newline, so a report a person reads ends its last line and a report
    /// a script reads is one ndJSON record.
    ///
    /// - Parameters:
    ///   - probed: What the agent reported.
    ///   - json: Whether the command line carried `--json`.
    /// - Throws: The encoding failure of the JSON form.
    private static func write(_ probed: ProbeReport, asJSON json: Bool) throws {
        let text = json ? try probed.jsonText() : probed.plainText()
        FileHandle.standardOutput.write(Data("\(text)\n".utf8))
    }
}
