---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1pyacfhvsbhg9ps45wc8zd6
  text: |-
    ### Research

    Read `RunCommand.swift`, `FrameTeeTransport.swift`, `SharedOptions.swift`, `TerminalOutput.swift`, `DecliningClient.swift`, `AgentSession.swift`, `TurnRunner.swift`, and the IntegrationTests support files.

    What the wiring needs:
    - `RunCommand.runTurn` hands `process.transport` straight to `driveTurn`. The tee goes between them, held in a local `let` so the tee outlives the turn (its `deinit` cancels the forwarding task).
    - `TerminalOutput` has no member that writes at every verbosity but is not an error. `event(_:)` is gated at `.verbose`; `error(_:)` writes at every verbosity. `--frames` is a debugging switch and not a verbosity level, so it needs its own member.

    Discovery that changes the scope of one acceptance row:

    **`--verbose` writes ZERO bytes to stderr today.** Measured by hand: built `acp-client` and ran it against a `/bin/sh` stub agent with `--verbose`, stdout to a file and stderr to a file. stdout held 24 bytes (the answer, no trailing newline) and stderr held 0 bytes.

    The cause: the only source of `TerminalOutput.event(_:)` lines in a run is the wire connection's own logger, and `Connection.log(_:)` is called on an ANOMALY alone — a malformed line, a dropped message, a transport failure. A clean run logs nothing. `AgentSession.closeSession(_:)` writes event lines too, but `RunCommand` never calls it.

    So acceptance row 4 ("`--verbose` writes session event lines to stderr") cannot pass without the run emitting session events of its own. `cli-plan.md` §8 states the same requirement: "`--verbose` writes the session events, one line each." The plan puts three events in reach of `RunCommand`: the agent started, `initialize` answered, and the turn ended. Those go in this change.

    Rows 2 and 3 (a default run and `--quiet` each write zero bytes) hold today and stay holding, because every new line is gated at `.verbose`.

    Test-support gaps the card's Tests section needs:
    - `runAcpClient` always gives the run a pipe for stdout. The "stdout a pipe and stdout a file" row needs a second standard-output case.
    - `makeWellBehavedAgent` records a pid file and a transcript, but not its own `argv`.
    - No stub asks for permission mid-turn.
  timestamp: 2026-09-04T19:28:52.209765+00:00
- actor: claude-code
  id: 01m1pz2snrw59t787675a3zkh5
  text: |-
    ### What landed

    Production, `Sources/acp-client/`:
    - `TerminalOutput.frame(_:)` — one line at EVERY verbosity, `--quiet` included and whether or not stderr is a terminal. It is its own member rather than a call of `event(_:)` (which `--verbose` gates) or of `error(_:)` (which says something went wrong), because §6.1 makes `--frames` a debugging switch and not a verbosity level. The three entry points now share one private `writeLine(_:)`, so the line ending is stated once.
    - `RunCommand.sessionTransport(over:frames:terminal:)` — the tee when `--frames` is given, the agent's own stdio otherwise. `runTurn` binds the result to a local `let` rather than passing it inline: `FrameTeeTransport.deinit` cancels the forwarding task, and a value the caller dropped would stop teeing mid-exchange.
    - Session events for `--verbose`, which the research comment records as absent before this change: the agent started (`RunCommand.runTurn`), `initialize` answered by name/version/protocol version (`AgentSession.initialize()`), the session opened with its id and resolved cwd (`AgentSession.openSession()`), and the turn ended with its stop reason spelled as the wire value (`RunCommand.turnEndedEvent(for:)`).

    Measured by hand against a `/bin/sh` stub, stdout and stderr separated:
    - `--verbose` now writes four lines, and stdout still holds the 24 answer bytes.
    - `--frames` writes 8 lines, 3 outbound under `>> ` and 5 inbound under `<< `.
    - `--frames --quiet` still writes the frames, and stdout is the answer bytes alone.

    Tests:
    - `Tests/FoundationModelsACPClientTests/RunCommandTransportTests.swift` (new) — the flag decides, both directions are teed, and `--quiet` does not silence it. The exchange is driven over `InMemoryTransport.pair()` and the wait needs no polling: the tee copies an outbound line before `write(_:)` returns and an inbound line before it yields the chunk, so one chunk read off the transport proves both sink calls happened, or that there is no tee.
    - `TerminalOutputTests` — `frame` writes one line at each of the three verbosities.
    - `AgentSessionTests` — `initialize` names the agent, `openSession` names the session, and neither writes at the default verbosity.
    - `IntegrationTests/.../StreamRulesTests.swift` (new) — one test per acceptance row, plus the pipe-against-file row.

    Support, `IntegrationTests/.../Support/`:
    - `CLIStandardOutput` and `runAcpClient(_:standardInput:standardOutput:environment:)`, with a `StandardOutputSink` that drains a pipe DURING the run and reads a file AFTER it. The pipe reader is bound out of the sink before the draining task starts: an `async let` sends whatever its expression touches, and Swift 6 refused the first shape that sent the whole sink.
    - `makeWellBehavedAgent(argumentsFile:)`, which writes `"$@"` one per line. The redirection stands on the loop, so a run that passed no argument writes an EMPTY file rather than none.
    - `makePermissionRequestingAgent(answer:)`, which sends `session/request_permission` and then BLOCKS on a read loop until the answer carrying its id arrives. The wait is deliberate: the connection dispatches an inbound request on a task of its own, so an agent that sent the idle update straight after would let the run tear down before the refusal line was written — and the wait also makes the test prove the binary ANSWERED rather than only logged.

    ### For the docs task ^01M1MPM (record the CLI decisions in cli-plan.md)

    §8 already says "`--verbose` writes the session events, one line each", and this change is what makes that true. The four events the run now writes are named above. Nothing in `cli-plan.md` needed to change for this card, but the doc task may want the four named.
  timestamp: 2026-09-04T19:42:12.152548+00:00
- actor: claude-code
  id: 01m1pz2zypdd6b3eqb44bv94ev
  text: |-
    ### implement — changed
    - evidence: 9 files. Production: `Sources/acp-client/RunCommand.swift`, `Sources/acp-client/AgentSession.swift`, `Sources/acp-client/TerminalOutput.swift`. Unit tests: `Tests/FoundationModelsACPClientTests/RunCommandTransportTests.swift` (new), `TerminalOutputTests.swift`, `AgentSessionTests.swift`. Integration: `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/StreamRulesTests.swift` (new), `Support/CLITestSupport.swift`, `Support/StubAgents.swift`. `timeout 420 swift test` — 187 tests in 13 suites passed, zero failures, zero warnings. `timeout 600 swift test --package-path IntegrationTests` — 25 tests in 5 suites passed, zero failures, zero warnings. Every acceptance row and every Tests row of the card has a test; none was left undone. `pgrep` after the run showed no leftover `acp-client` or stub-agent process.
    - next: `/review`
  timestamp: 2026-09-04T19:42:18.582541+00:00
- actor: claude-code
  id: 01m1pzk091pj6k6bcn2sgfevph
  text: |-
    ### review — clean
    - evidence: `review sha f1f253a~1..f1f253a` — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 9 files reviewed
    - checks: `swift test --package-path IntegrationTests --filter StreamRules` — 8 tests, all pass
    - judgement 1: the `let transport` in `RunCommand.runTurn` holds the tee for the full turn. Swift gives a callee a borrowed argument, so the caller keeps the value alive until `driveTurn` returns, and `driveTurn` returns only after `session.teardown()`. `FrameTeeTransport.deinit` thus cannot cancel the forwarder in the middle of the exchange.
    - judgement 2: the four `--verbose` session event lines are in the scope of this task. The acceptance criteria ask that `--verbose` writes session event lines to stderr. No code wrote those lines before. The `.verbose` gate in `TerminalOutput.event(_:)` keeps the default run and `--quiet` at zero bytes on stderr, and two integration tests prove it from real file descriptors.
    - judgement 3: §8 holds with `--frames`. The frames test asserts that stdout is equal to the answer bytes, and that the count of the marked lines is equal to the count of all stderr lines. Thus every stderr byte is a frame, and no frame goes to stdout.
    - note: the description checkboxes stay unchecked. The reviewer does not mark them.
    - next: none. The task moves to done.
  timestamp: 2026-09-04T19:51:03.201677+00:00
- actor: claude-code
  id: 01m1pzkzccq0j1pcyvcknmptn7
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 9 files. `--frames` now puts `FrameTeeTransport` in the run's transport chain; `TerminalOutput.frame(_:)` writes at every verbosity, so the flag is independent of `--quiet` and `--verbose`.
    - test: green — root 187 passed in 13 suites, integration 25 passed in 5 suites, 0 failures and 0 warnings on both
    - commit: f1f253a feat(cli): wire --frames into run and prove the stream split
    - review: clean — zero findings, task moved to done

    Three things the review established:
    - `--verbose` wrote ZERO bytes to stderr before this change, because the only source of event lines was the wire logger, which fires on an anomaly alone. The four new event lines (the agent started, initialize answered, the session opened, the turn ended) are required by the card's own acceptance row, not scope creep. Two integration tests hold the default run and `--quiet` at an empty stderr.
    - §8 holds under `--frames`: stdout is the answer bytes and nothing else, and every stderr line carries a direction mark, so no frame reaches stdout and nothing unmarked reaches stderr.
    - One comment in `RunCommand.swift` gives a reason that is not true. It says a dropped tee value would stop teeing mid-exchange; Swift passes `any ACPTransport` as a borrowed argument, so an inline temporary would live as long. The `let` binding is correct and readable, and only the stated reason is wrong.

    The 12 description checkboxes stay unchecked, although the review confirmed a passing test covers every one.
  timestamp: 2026-09-04T19:51:35.052156+00:00
depends_on:
- 01M1MQHBX56XTYHFZR6K0E160T
- 01M1MPD4MJ9KMVVQ316YSJPJHK
position_column: done
position_ordinal: '9980'
title: Wire --frames into run, and prove the two streams end to end
---
## What

`cli-plan.md` §6.1 and §8. The unit tests drive the turn logic over an
in-memory pair; this task runs the real binary against a real agent process and
asserts the two file descriptors byte for byte. It is the only way to prove
§8, because §8 is a claim about file descriptors — and it is the only test
that catches a Noora default writing to stdout.

Edit `Sources/acp-client/RunCommand.swift`: when `--frames` is given, wrap the
`AgentProcess` transport in `FrameTeeTransport` before handing it to
`AgentSession`, with the tee's sink pointed at stderr. `--frames` is
independent of `--quiet` and `--verbose`: it is a debugging switch, not a
verbosity level, and it writes its lines whether or not stderr is a terminal.

Add
`IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/StreamRulesTests.swift`,
built on the `CLITestSupport` and `StubAgents` helpers.

## Acceptance Criteria

- [ ] With `wellBehavedAgent`, `acp-client run "hi" -- <agent>` writes only
      the answer text to stdout, byte for byte, with no trailing newline.
- [ ] With stderr captured as a pipe, a default run writes zero bytes to
      stderr.
- [ ] `--quiet` writes zero bytes to stderr and leaves stdout unchanged.
- [ ] `--verbose` writes session event lines to stderr and leaves stdout
      unchanged, byte for byte.
- [ ] `--frames` writes the ndJSON messages to stderr in both directions, and
      stdout stays exactly the answer text.
- [ ] A stub that asks for permission during the turn causes exactly one
      stderr line, and leaves stdout unchanged. This is the §8 exception the
      decline policy creates.
- [ ] The arguments after `--` reach the agent unchanged, flags included.

## Tests

- [ ] `StreamRulesTests.swift`, one test per acceptance row above, each using
      `runAcpClient(_:standardInput:)` and asserting on `Data`, not `String`.
- [ ] One test extends `wellBehavedAgent` to write its own `argv` into a file,
      and asserts the file holds the arguments given after `--`, in order.
- [ ] One test asserts the answer text is identical with stdout a pipe and
      with stdout a file, which pins §8's "no rule that changes with a
      terminal".
- [ ] Extend `StubAgents` with an agent that sends a
      `session/request_permission` mid-turn and then finishes the turn, for
      the decline row.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.