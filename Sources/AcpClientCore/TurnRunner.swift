// `TurnRunner` — the turn of `cli-plan.md` §8: send one prompt, stream the
// answer as it arrives, and detect the end of the turn.
//
// This type holds NO process handling. `AgentSession` gives it a live
// connection and an update stream, and `RunCommand` owns the `AgentProcess`.
// That split is the whole reason this file is unit-testable over
// `InMemoryTransport.pair()`: no binary is started, and no test waits on a
// pipe.
//
// Six decisions here are not free choices.
//
// 1. The turn ends on a `state_update` that reports `idle`, and NOT on the
//    prompt answer. In v2 `PromptResponse` carries only `meta`: it says the
//    prompt was accepted, and it names no stop reason. So the prompt and the
//    reading run beside each other in one task group, and only `idle` ends
//    the turn. A prompt that fails still ends the group, because an `idle`
//    the agent will never send is not worth waiting for.
// 2. `IdleStateUpdate.stopReason` is optional, and the schema says "Omitted
//    or `null` both mean the agent is not reporting a stop reason". So the
//    end of the turn is read off `idle` ARRIVING, never off a value being
//    present, and an absent reason gives ``TurnOutcome/idleWithNoReason``.
// 3. A thought chunk is the agent's reasoning and not its answer. §8 keeps
//    standard output for the answer alone, so a thought reaches the
//    observable container behind the connection and never reaches the sink.
// 4. The sink takes `Data` and not `String`, because §8 wants the answer
//    bytes verbatim: nothing added, no trailing newline and no colour, in a
//    terminal and in a pipe alike. One write per chunk is one flush per
//    chunk, so the answer leaves this binary as fast as it arrives.
// 5. The `--timeout` limit of §6.1 is a CHILD of that same task group, and
//    never a limiter task racing it from outside. `AgentCommandDoctor` does
//    race one from outside, and it reads a `CancellationError` as "the limit
//    ended first"; that reading is sound there because the raced work is one
//    `Connection.call`, which fails a cancelled request with exactly that
//    error. It is not sound here. By the time a limit lands, the prompt has
//    usually already been answered, so cancelling this group makes the reader
//    end its stream and `run()` throw ``TurnEndedWithoutIdleError`` instead —
//    a race between two errors that mean different things. A child that
//    sleeps and then throws ``AcpClientTimeout`` has no such race: the group
//    IS the race, the throw is the limit and nothing else, and
//    `withThrowingTaskGroup` cancels and drains the other children on the way
//    out, so no task is left running behind the exit.
//    The `Ctrl-C` handling of §11 is a child of the same group for the same
//    reason, and its first press does one thing the limit does NOT: it sends
//    `session/cancel` and keeps waiting. §11 asks for a turn that is CANCELLED
//    on the wire and then reports its own `cancelled` stop reason, rather than
//    a turn that was merely abandoned. Only the second press ends the wait,
//    and it throws in exactly the way the limit does.
// 6. The group's element says WHICH child finished, and never merely "with no
//    outcome". Three children finish carrying no outcome, and they do not mean
//    the same thing: the prompt acknowledgement and the spinner leave the turn
//    running, while the reader's stream ending means the agent went away and
//    no `idle` can ever arrive. An element type that folded those three into
//    one `nil` made the reader's ending look like nothing at all — and with a
//    limit set, the sleeping child was then the only child left, so the run
//    waited out a limit nothing had reached and reported that limit in place
//    of ``TurnEndedWithoutIdleError``. ``TurnEvent`` keeps the three apart.
//
// The spinner is the third child of the group, and a stream of tool names
// joins it to the reading. ``TerminalOutput/withSpinner(_:_:)`` draws for
// exactly as long as its body runs, and the body here is one loop over that
// stream: each name it reads rewrites the drawn line in place, and the
// stream ending ends the spinner. The reader ends the stream at the first
// answer chunk, which is where §8 stops the spinner, and again when the turn
// ends, for a turn that carried no answer text at all. So the reading stays
// one loop and one `for await`, and the spinner still starts at the prompt
// and stops at the first chunk.
//
// One name to watch. `FoundationModelsACP` exports a `TerminalOutput` of its
// own — the ACP model of what an agent-owned terminal printed. Inside this
// target the local type wins the lookup, and the local type is the one this
// file means.

import Foundation
import FoundationModelsACP

/// Why one turn ended.
///
/// The two cases are the two shapes an `idle` state update takes, and
/// nothing else ends a turn.
enum TurnOutcome: Sendable, Equatable {
    /// The agent went idle and named a stop reason.
    case stopped(StopReason)

    /// The agent went idle and named no stop reason.
    ///
    /// `IdleStateUpdate.stopReason` is optional, and an agent that went idle
    /// without saying why still went idle, so this is a completed turn.
    case idleWithNoReason

    /// Reads the outcome off one idle update's optional stop reason.
    ///
    /// - Parameter stopReason: The reason the agent reported, or `nil` when
    ///   it reported none.
    init(stopReason: StopReason?) {
        guard let stopReason else {
            self = .idleWithNoReason
            return
        }
        self = .stopped(stopReason)
    }
}

/// The failure ``TurnRunner/run()`` throws when the agent's update stream
/// ended before the agent reported `idle`.
///
/// An agent that went away in the middle of a turn gave no outcome at all,
/// and reporting a completed turn for it would send a broken run to the
/// success row of `cli-plan.md` §9. It is an error instead, which that table
/// sends to the row owning a protocol failure.
struct TurnEndedWithoutIdleError: Error, CustomStringConvertible {
    /// A human-readable description of this error.
    var description: String {
        "The agent's update stream ended before the agent reported that it was idle."
    }
}

/// What one `Ctrl-C` asks of the running turn (`cli-plan.md` §11).
///
/// The two cases are the two presses that section names, and the counting that
/// tells them apart lives in ``InterruptHandler`` rather than here: this type
/// says what to DO, so a reader of ``TurnRunner`` sees the two behaviours
/// spelled out and never a press number to interpret.
enum TurnInterrupt: Sendable {
    /// Send `session/cancel`, and keep waiting for the agent's own `idle`
    /// update. §11 gives the first press this, so the answer that arrived
    /// stays written and the turn ends with the `cancelled` stop reason §9
    /// sends to code 4.
    case cancelTurn

    /// End the run at once, with no further wait on the agent. §11 gives the
    /// second press this.
    case endRunAtOnce
}

/// The text this file draws on standard error.
///
/// It lives outside ``TurnRunner`` because the spinner runs on a task of its
/// own, and a static member of a main-actor type could not be read there.
private enum TurnRunnerText {
    /// The neutral label the spinner carries.
    ///
    /// §8 asks for a spinner that makes no claim about what the agent is
    /// doing, because a foreign agent may be downloading a model and this
    /// binary cannot know.
    static let spinnerLabel = "Waiting for the agent"
}

/// One prompt, the answer streamed to a sink, and the end of the turn.
///
/// A value of this type holds no process and no path. It drives the agent
/// through the ``AgentSession`` it was given, and it hands every answer byte
/// to the sink it was given, which production points at standard output and
/// a test points at a buffer.
@MainActor
struct TurnRunner {
    /// The connected, initialized agent this turn runs against.
    private let session: AgentSession

    /// The prompt of the turn.
    private let prompt: String

    /// The terminal layer that owns standard error.
    private let output: TerminalOutput

    /// Receives the answer bytes, verbatim.
    ///
    /// It is called once per answer chunk, with the bytes of that chunk and
    /// nothing else, so the caller writes and flushes as the answer arrives.
    private let answerSink: @Sendable (Data) -> Void

    /// The longest the turn may run, or `nil` for no limit.
    private let limit: Duration?

    /// The interrupts of the run, or `nil` for a turn that catches none.
    ///
    /// `nil` is the shape a caller that installed no ``InterruptHandler``
    /// gives, and it adds no child to the task group at all — the same shape
    /// ``limit`` takes for a run that carried no `--timeout`.
    private let interrupts: AsyncStream<TurnInterrupt>?

    /// Builds the runner.
    ///
    /// - Parameters:
    ///   - session: The connected, initialized agent to run the turn against.
    ///   - prompt: The prompt of the turn.
    ///   - terminal: The layer that owns standard error.
    ///   - answerSink: Receives the answer bytes, verbatim.
    ///   - limit: The longest the turn may run. The default is `nil`, which is
    ///     the "no limit" `cli-plan.md` §6.1 gives a run that carried no
    ///     `--timeout`.
    ///   - interrupts: The interrupts of the run. The default is `nil`, which
    ///     is a turn no `Ctrl-C` reaches.
    init(
        session: AgentSession,
        prompt: String,
        terminal: TerminalOutput,
        answerSink: @escaping @Sendable (Data) -> Void,
        limit: Duration? = nil,
        interrupts: AsyncStream<TurnInterrupt>? = nil
    ) {
        self.session = session
        self.prompt = prompt
        output = terminal
        self.answerSink = answerSink
        self.limit = limit
        self.interrupts = interrupts
    }

    /// Runs one turn: opens a session, sends the prompt, streams the answer,
    /// and ends when the agent reports `idle`.
    ///
    /// The prompt, the spinner and the reading are three children of one
    /// task group, because the prompt answer does not end the turn and a
    /// prompt that fails must not leave the reading waiting forever. A run
    /// that carried `--timeout` adds the limit as a fourth child — see rule 5
    /// at the head of this file for why the limit is a child and not a race
    /// from outside.
    ///
    /// Only the reading can end the turn. The prompt and the spinner report
    /// ``TurnEvent/sideWorkFinished``, which leaves the turn running, and the
    /// reader reports the end of the turn one way or the other: the outcome an
    /// `idle` carried, or the stream ending with no `idle` on it at all. See
    /// rule 6 at the head of this file for what a shared "no outcome" cost.
    ///
    /// - Returns: Why the turn ended.
    /// - Throws: ``AcpClientTimeout`` when the turn reached its limit,
    ///   ``TurnEndedWithoutIdleError`` when the stream ended first,
    ///   ``ProcessWorkingDirectoryError`` when `--cwd` is absent and this
    ///   process has no working directory, `RequestError` on a peer error, or
    ///   `ConnectionError` when the agent went away.
    func run() async throws -> TurnOutcome {
        let (sessionId, updates) = try await session.openSession()
        let (toolNames, toolNameFeed) = AsyncStream<String>.makeStream()
        return try await withThrowingTaskGroup(of: TurnEvent.self) { group in
            group.addTask {
                try await self.sendPrompt(for: sessionId)
                // The acknowledgement never ends the turn.
                return .sideWorkFinished
            }
            group.addTask { [output] in
                try await output.withSpinner(TurnRunnerText.spinnerLabel) { reportToolName in
                    for await name in toolNames {
                        reportToolName(name)
                    }
                }
                return .sideWorkFinished
            }
            group.addTask {
                let outcome = await self.readTurn(
                    from: updates,
                    reportingToolNamesTo: toolNameFeed
                )
                guard let outcome else { return .streamEndedWithoutIdle }
                return .turnEnded(outcome)
            }
            if let limit {
                group.addTask {
                    try await Task.sleep(for: limit)
                    throw AcpClientTimeout()
                }
            }
            if let interrupts {
                group.addTask {
                    try await self.applyInterrupts(from: interrupts, to: sessionId)
                    // The stream ended with no second press on it, so the
                    // interrupts are over and the turn is not.
                    return .sideWorkFinished
                }
            }
            while let event = try await group.next() {
                switch event {
                case .turnEnded(let outcome):
                    // The return leaves the children running, and a limit that
                    // is still sleeping would hold the group open until it ends.
                    group.cancelAll()
                    return outcome
                case .streamEndedWithoutIdle:
                    // The throw cancels and drains every other child on its way
                    // out, the sleeping limit among them.
                    throw TurnEndedWithoutIdleError()
                case .sideWorkFinished:
                    continue
                }
            }
            // Every child finished and none of them ended the turn, which the
            // reader's two events leave no room for. The turn still has no
            // outcome, so it owes the same failure rather than an invented one.
            throw TurnEndedWithoutIdleError()
        }
    }

    /// Sends the prompt of the turn.
    ///
    /// - Parameter sessionId: The session to prompt.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` when
    ///   the agent went away.
    private func sendPrompt(for sessionId: SessionId) async throws {
        _ = try await session.connection.prompt(
            PromptRequest(prompt: [.text(TextContent(text: prompt))], sessionId: sessionId)
        )
    }

    /// Applies each interrupt of the run to the live turn.
    ///
    /// The first press sends `session/cancel` and returns to the stream: the
    /// schema confirms a cancellation with an `idle` update carrying
    /// `cancelled`, never with the notification returning, so the reading is
    /// still what ends the turn and `cli-plan.md` §9 still gives that outcome
    /// its own code. The second press has no such update to wait for, so it
    /// throws and the group cancels every other child on the way out.
    ///
    /// A `session/cancel` that cannot reach a dead agent throws, and that
    /// throw is left alone: the run really did fail on the wire, and §9 sends
    /// it to the protocol-failure row, exactly as it sends the reader's own
    /// ``TurnEndedWithoutIdleError`` there.
    ///
    /// - Parameters:
    ///   - interrupts: The interrupts of the run.
    ///   - sessionId: The session to cancel.
    /// - Throws: ``AcpClientInterrupted`` on the second interrupt, or
    ///   `ConnectionError` when the agent went away before the cancellation
    ///   could reach it.
    private func applyInterrupts(
        from interrupts: AsyncStream<TurnInterrupt>,
        to sessionId: SessionId
    ) async throws {
        for await interrupt in interrupts {
            switch interrupt {
            case .cancelTurn:
                try await session.connection.sessionCancel(
                    CancelSessionNotification(sessionId: sessionId)
                )
            case .endRunAtOnce:
                throw AcpClientInterrupted()
            }
        }
    }

    /// Reads the session's updates until the agent reports `idle`.
    ///
    /// - Parameters:
    ///   - updates: The session's update stream.
    ///   - toolNameFeed: Where the running tool name goes, which is the
    ///     spinner's line. It ends at the first answer chunk, because §8
    ///     stops the spinner there, and at the end of the turn, for a turn
    ///     that carried no answer text at all.
    /// - Returns: Why the turn ended, or `nil` when the stream ended first.
    private func readTurn(
        from updates: AsyncStream<SessionUpdate>,
        reportingToolNamesTo toolNameFeed: AsyncStream<String>.Continuation
    ) async -> TurnOutcome? {
        defer { toolNameFeed.finish() }
        for await update in updates {
            switch apply(update, reportingToolNamesTo: toolNameFeed) {
            case .turnEnded(let outcome):
                return outcome
            case .answerWritten:
                toolNameFeed.finish()
            case .ignored:
                continue
            }
        }
        return nil
    }

    /// Applies one update: writes an answer chunk, reports a tool name, or
    /// reads the end of the turn.
    ///
    /// Every other update — a thought chunk among them — is the container's
    /// business and not this sink's, so it changes nothing here.
    ///
    /// - Parameters:
    ///   - update: The update to apply.
    ///   - toolNameFeed: Where the running tool name goes.
    /// - Returns: What the update did.
    private func apply(
        _ update: SessionUpdate,
        reportingToolNamesTo toolNameFeed: AsyncStream<String>.Continuation
    ) -> UpdateEffect {
        if case .agentMessageChunk(let chunk) = update {
            return write(chunk.content)
        }
        if case .stateUpdate(.idle(let idle)) = update {
            return .turnEnded(TurnOutcome(stopReason: idle.stopReason))
        }
        if case .toolCallUpdate(let toolCall) = update, case .value(let title) = toolCall.title {
            toolNameFeed.yield(title)
        }
        return .ignored
    }

    /// Writes one answer chunk's text to the sink, verbatim.
    ///
    /// A chunk that carries an image, an audio clip or a resource carries no
    /// answer text, and §8 keeps standard output for the answer text alone.
    ///
    /// - Parameter content: The content block of one answer chunk.
    /// - Returns: What the chunk did.
    private func write(_ content: ContentBlock) -> UpdateEffect {
        guard case .text(let text) = content else { return .ignored }
        answerSink(Data(text.text.utf8))
        return .answerWritten
    }
}

/// What one child of the turn's task group reported when it finished.
///
/// Only ``turnEnded`` and ``streamEndedWithoutIdle`` end the turn, and the
/// reading is the only child that reports either. See rule 6 at the head of
/// this file for why the three cases are kept apart.
private enum TurnEvent: Sendable {
    /// The agent reported `idle`, and this is the outcome that update carried.
    case turnEnded(TurnOutcome)

    /// The agent's update stream ended with no `idle` on it, so the turn has no
    /// outcome and can never get one. The agent went away.
    case streamEndedWithoutIdle

    /// A child that cannot end the turn finished: the prompt was acknowledged,
    /// or the spinner stopped.
    case sideWorkFinished
}

/// What one update did to the turn.
private enum UpdateEffect {
    /// The agent reported `idle`, and the turn is over.
    case turnEnded(TurnOutcome)

    /// The update carried answer text, and the text reached the sink.
    case answerWritten

    /// The update belongs to the observable container and not to the sink.
    case ignored
}
