import ArgumentParser
import Foundation
import FoundationModelsACP
import FoundationModelsACPClient

// `RunCommand` — the default subcommand of `cli-plan.md` §6, and the one type
// of this target that owns an agent process.
//
// The split is deliberate. `TurnRunner` holds NO process handling, so it stays
// unit-testable over an in-memory transport; `AgentSession` starts nothing, so
// the caller decides what is on the far end of the wire. That leaves this file
// with the three things only a real run has: the spawn, the reap, and the exit
// code.
//
// Four decisions here are not free choices.
//
// 1. **The reap is a `defer`.** §11 lets no agent outlive the run, and a leaked
//    agent holds gigabytes of model weights. A completed turn, a thrown error
//    and a cancellation all pass through the `defer`, and
//    `AgentProcess.shutdown()` is idempotent, so the second reap — the one the
//    reader thread runs at end of file — costs nothing.
// 2. **The prompt is resolved before the agent is started.** The §7 row that
//    has no prompt to read is a usage error, and a usage error must not leave a
//    started agent behind. Resolving first means that row spawns nothing at
//    all.
// 3. **The outcome leaves through `AcpClientExitCode`.** A success returns
//    normally, so the process ends through its own exit path; every other row
//    is thrown as the parser's `ExitCode`, which prints nothing and carries the
//    number. Standard output stays the answer text and nothing else, which is
//    what §8 asks for.
// 4. **The `Ctrl-C` handler is armed around the SPAWN, and torn down after the
//    reap.** §11 gives the interrupt an agent to cancel and an agent to reap,
//    and both facts start at the spawn. The two `defer`s run in reverse order,
//    so the agent is gone before the `SIGINT` disposition goes back to the one
//    that ends this process — a press in that window would otherwise kill the
//    binary with the agent still running. Arming EARLIER would be worse in the
//    other direction: the disposition is `SIG_IGN` while the handler is armed,
//    so a press before there is a turn to cancel would be swallowed whole.
//
// One name to watch. `FoundationModelsACP` exports a `TerminalOutput` of its
// own — the ACP model of what an agent-owned terminal printed. Inside this
// target the local type wins the lookup, and the local type is the one this
// file means.

/// `acp-client run` — start the agent, run one turn, print the answer, and exit
/// (`cli-plan.md` §6).
///
/// This is the default subcommand, so `acp-client -- <agent-command>` runs a
/// turn without naming `run`.
struct RunCommand: AsyncParsableCommand {
    /// The name of this subcommand on the command line.
    static let name = "run"

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

    /// Receives every answer byte, and writes it to this binary's own standard
    /// output, verbatim.
    ///
    /// `cli-plan.md` §8 keeps standard output for the answer text alone, and
    /// one write per chunk is one flush per chunk, so the answer leaves this
    /// binary as fast as it arrives.
    private static let answerSink: @Sendable (Data) -> Void = {
        FileHandle.standardOutput.write($0)
    }

    /// Runs one turn against the agent.
    ///
    /// - Throws: `ValidationError` for the §7 row that has no prompt to read
    ///   and for an invocation naming no agent, which ArgumentParser turns into
    ///   the usage text on stderr and the usage row of `cli-plan.md` §9; or an
    ///   `ExitCode` carrying the row of §9 the outcome owes.
    func run() async throws {
        let terminal = TerminalOutput(
            verbosity: TerminalVerbosity(quiet: options.quiet, verbose: options.verbose)
        )
        let promptText = try Self.promptForTurn(argument: prompt)
        let agent = try invocation.command()

        let outcome: TurnOutcome
        do {
            outcome = try await Self.runTurn(
                agent: agent,
                prompt: promptText,
                cwd: options.cwd,
                frames: options.frames,
                limit: options.turnLimit,
                terminal: terminal
            )
        } catch {
            // Every failure gets one line on stderr. §8 leaves a default run
            // silent there UNTIL it fails, and a run that failed without a word
            // is a run nobody can debug.
            terminal.error(String(describing: error))
            throw AcpClientExitCode.forError(error).parserExitCode
        }

        // The end of the turn is the last session event, and `--verbose` is
        // the only place it can be reported: §8 gives standard output the
        // answer text and no stop reason at all, and the exit code carries the
        // outcome to a script rather than to a person.
        terminal.event(Self.turnEndedEvent(for: outcome))

        let outcomeCode = Self.exitCode(for: outcome)
        guard outcomeCode != .success else { return }
        throw outcomeCode.parserExitCode
    }

    /// Resolves where the prompt of this turn comes from.
    ///
    /// The one §7 row that can produce no prompt — no argument, with standard
    /// input a terminal — becomes a `ValidationError`, because that is what
    /// ArgumentParser turns into the usage text on stderr and the usage row of
    /// `cli-plan.md` §9. Standard output is untouched either way.
    ///
    /// - Parameter argument: The prompt argument the command line carried, or
    ///   `nil` when it carried none.
    /// - Returns: The prompt text, verbatim.
    /// - Throws: `ValidationError` for the §7 row that has no prompt to read,
    ///   or whatever the read of standard input threw.
    private static func promptForTurn(argument: String?) throws -> String {
        do {
            return try PromptSource().prompt(from: argument)
        } catch PromptSourceError.noPromptAndStdinIsATerminal {
            throw ValidationError(PromptSourceError.noPromptAndStdinIsATerminal.description)
        }
    }

    /// Starts the agent, drives one turn against it, and reaps it on every
    /// path.
    ///
    /// - Parameters:
    ///   - agent: The agent executable and its own arguments.
    ///   - prompt: The prompt of the turn.
    ///   - cwd: The `--cwd` value, or `nil` for the process working directory.
    ///   - frames: Whether the command line carried `--frames`.
    ///   - limit: The `--timeout` limit of the turn, or `nil` for no limit.
    ///   - terminal: The layer that owns standard error.
    /// - Returns: Why the turn ended.
    /// - Throws: ``AgentCommandResolutionFailure`` when the command resolves to
    ///   no executable, `AgentProcessError` when the spawn fails, or whatever
    ///   the turn itself threw — ``AcpClientTimeout`` and
    ///   ``AcpClientInterrupted`` among it, which the `defer`s above reap the
    ///   agent on exactly as they reap every other row.
    private static func runTurn(
        agent: AgentCommand,
        prompt: String,
        cwd: String?,
        frames: Bool,
        limit: Duration?,
        terminal: TerminalOutput
    ) async throws -> TurnOutcome {
        let executable = try AgentCommandResolver().resolve(agent.executable)
        let (interrupts, interruptFeed) = AsyncStream<TurnInterrupt>.makeStream()
        let interruptHandler = InterruptHandler(
            onFirstInterrupt: { interruptFeed.yield(.cancelTurn) },
            onSecondInterrupt: { interruptFeed.yield(.endRunAtOnce) }
        )
        interruptHandler.start()
        defer {
            interruptHandler.stop()
            interruptFeed.finish()
        }
        let process = try AgentProcess(command: executable, arguments: agent.arguments)
        // This `defer` runs BEFORE the one above, so the agent is reaped while
        // `SIGINT` is still ignored. See decision 4 at the head of this file.
        defer { process.shutdown() }
        terminal.event("the agent started: \(executable)")
        // The tee is bound here rather than passed inline, so it outlives the
        // turn: `FrameTeeTransport.deinit` cancels the forwarding task that
        // copies the agent's lines, and a value the caller dropped would stop
        // teeing in the middle of the exchange.
        let transport = sessionTransport(
            over: process.transport,
            frames: frames,
            terminal: terminal
        )
        return try await driveTurn(
            over: transport,
            prompt: prompt,
            cwd: cwd,
            limit: limit,
            interrupts: interrupts,
            terminal: terminal
        )
    }

    /// Returns the transport ``AgentSession`` runs over.
    ///
    /// With `--frames` that is the agent's stdio behind a
    /// ``FrameTeeTransport`` pointed at standard error, which is the whole of
    /// what `cli-plan.md` §6.1 asks for: "write every ndJSON message to
    /// stderr, in both directions, with a direction mark". Without the flag it
    /// is the agent's stdio itself, so a default run pays nothing for a
    /// debugging switch it did not ask for.
    ///
    /// The tee writes through ``TerminalOutput/frame(_:)`` and not through
    /// ``TerminalOutput/event(_:)``, because `--frames` is independent of
    /// `--quiet` and `--verbose`: it is a debugging switch and not a verbosity
    /// level, and it writes its lines whether or not stderr is a terminal.
    ///
    /// - Parameters:
    ///   - agentTransport: The started agent's stdio.
    ///   - frames: Whether the command line carried `--frames`.
    ///   - terminal: The layer that owns standard error.
    /// - Returns: The transport to hand ``AgentSession``.
    static func sessionTransport(
        over agentTransport: any ACPTransport,
        frames: Bool,
        terminal: TerminalOutput
    ) -> any ACPTransport {
        guard frames else { return agentTransport }
        return FrameTeeTransport(wrapping: agentTransport) { terminal.frame($0) }
    }

    /// Connects to the started agent, runs the turn, and closes the connection
    /// on every path.
    ///
    /// A `defer` cannot `await`, so the outcome is held either way and the one
    /// teardown runs on the single path that follows. Closing rejects every
    /// pending request and flushes the container's buffered chunks, so nothing
    /// the agent already sent is left unwritten.
    ///
    /// - Parameters:
    ///   - transport: The started agent's stdio.
    ///   - prompt: The prompt of the turn.
    ///   - cwd: The `--cwd` value, or `nil` for the process working directory.
    ///   - limit: The `--timeout` limit of the turn, or `nil` for no limit.
    ///   - interrupts: The interrupts a `Ctrl-C` puts into the turn.
    ///   - terminal: The layer that owns standard error.
    /// - Returns: Why the turn ended.
    /// - Throws: `ProtocolVersionMismatchError` when the agent answered
    ///   `initialize` with another version, ``ProcessWorkingDirectoryError``
    ///   when `--cwd` is absent and this process has no working directory,
    ///   ``AcpClientTimeout`` when the turn
    ///   reached its limit, ``AcpClientInterrupted`` when a second `Ctrl-C`
    ///   ended the run, ``TurnEndedWithoutIdleError`` when the agent went
    ///   away in the middle of the turn, `RequestError` on a peer error, or
    ///   `ConnectionError` when the agent went away.
    @MainActor
    private static func driveTurn(
        over transport: any ACPTransport,
        prompt: String,
        cwd: String?,
        limit: Duration?,
        interrupts: AsyncStream<TurnInterrupt>,
        terminal: TerminalOutput
    ) async throws -> TurnOutcome {
        let session = await AgentSession(over: transport, terminal: terminal, cwd: cwd)
        let outcome: Result<TurnOutcome, any Error>
        do {
            _ = try await session.initialize()
            outcome = .success(
                try await TurnRunner(
                    session: session,
                    prompt: prompt,
                    terminal: terminal,
                    answerSink: answerSink,
                    limit: limit,
                    interrupts: interrupts
                ).run()
            )
        } catch {
            outcome = .failure(error)
        }
        await session.teardown()
        return try outcome.get()
    }

    /// Renders the end of the turn as the session event line `--verbose`
    /// writes.
    ///
    /// The stop reason is spelled with its wire value, because that is the
    /// text the agent put on the wire and the text a person compares against
    /// the agent's own log.
    ///
    /// - Parameter outcome: Why the turn ended.
    /// - Returns: The event line, without a terminator.
    private static func turnEndedEvent(for outcome: TurnOutcome) -> String {
        switch outcome {
        case .stopped(let reason):
            "the turn ended: \(reason.wireValue)"
        case .idleWithNoReason:
            "the turn ended, and the agent reported no stop reason"
        }
    }

    /// Returns the exit code `cli-plan.md` §9 gives one turn outcome.
    ///
    /// - Parameter outcome: Why the turn ended.
    /// - Returns: The row of the table that outcome owes.
    private static func exitCode(for outcome: TurnOutcome) -> AcpClientExitCode {
        switch outcome {
        case .stopped(let reason):
            AcpClientExitCode.forStopReason(reason)
        case .idleWithNoReason:
            AcpClientExitCode.idleWithNoReason
        }
    }
}
