---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1qn1cp5bks74db3q62f9qgt
  text: |-
    Picked up. Research done.

    **Paths on the card were stale.** The CLI code lives in `Sources/AcpClientCore/`, not `Sources/acp-client/` (`Sources/acp-client/` holds the `@main` type alone). The card's "What" text is corrected in place: `InterruptHandler.swift` and `TurnRunner.swift` both go in `Sources/AcpClientCore/`.

    What the code already gives:
    - `TurnRunner.run()` is a `withThrowingTaskGroup` over a named `TurnEvent`. Rules 5 and 6 at the head of that file record why an outer race does NOT work: `readTurn` loops over an `AsyncStream`, and cancellation FINISHES that stream rather than throwing. So the interrupt is a FIFTH child of the same group, beside the `--timeout` child.
    - `ClientSideConnection.sessionCancel(_:)` takes `CancelSessionNotification(sessionId:)` and reaches the wire as `session/cancel` (`MethodTable.generated.swift`). Its own doc says cancellation is confirmed by an `idle` `state_update` carrying `cancelled`, never by the notification returning — which is exactly the first-interrupt wait §11 asks for.
    - `AcpClientExitCode.forStopReason(.cancelled)` already answers 4, so the FIRST-interrupt path needs no exit-code change. The SECOND-interrupt path has no stop reason to stand on, so it needs its own error and its own row in `forError(_:)`, in the shape `AcpClientTimeout` already has.
    - `TerminalOutput` builds Noora's `Terminal` with `signalBehavior: .none` deliberately. Left alone.

    Design decided:
    - `InterruptHandler` keeps the counter in a `Mutex<Int>` and dispatches UNDER the lock, so the first and the second callback each run one time and in order whatever the interleaving. `start()` installs `SIG_IGN` and the `DispatchSourceSignal`; `stop()` restores `SIG_DFL`. `init` installs nothing, so a unit test can drive `deliver()` without touching the test runner's own SIGINT.
    - The source's event handler reads `source.data` and delivers that many times, because a `DispatchSourceSignal` COALESCES a fast double press into one event carrying a count of 2.
    - `TurnRunner` takes an `AsyncStream<TurnInterrupt>?`, defaulting to `nil`, in the same shape as `limit`. `.cancelTurn` sends `session/cancel` and keeps waiting for `idle`; `.endRunAtOnce` throws `AcpClientInterrupted`.
  timestamp: 2026-09-05T02:05:54.757353+00:00
- actor: claude-code
  id: 01m1qnvvcfk7apj62p6etqbkqb
  text: |-
    Implementation landed. Notes for the next reader.

    **The card's paths were stale and are now corrected in the description.** `Sources/acp-client/` holds the `@main` type alone; both files went into `Sources/AcpClientCore/`.

    Two things the tests found that the design had to answer:

    1. **A `DispatchSourceSignal` COALESCES.** Two `SIGINT`s that land between two handler calls reach ONE event carrying `data == 2`. A handler that delivered once per event would read the two presses §11 tells apart as one, and the second press would never arrive. `deliver(times:)` takes the count and the event handler passes `source.data`.
    2. **`SIG_IGN` has to go in BEFORE the source is made.** A dispatch signal source does not replace the disposition, it watches beside it, so an armed source alone still dies on the first press. This is decision 1 at the head of `InterruptHandler.swift`.

    What did NOT work, so nobody repeats it:

    - **A stdout byte assertion on the two-press row.** The first version of `twoInterruptsEndARunWhoseAgentIgnoresTheCancellation()` asserted the answer bytes beside the exit code, and it failed: the second press ends the run AT ONCE, so a chunk still in flight when it lands has no moment left in which to be written. §11 gives "prints the text that arrived" to the FIRST press, which waits for the agent. The byte claim now lives on `theAnswerThatArrivedBeforeTheInterruptIsStillWritten()` alone, and the two-press test says so in its own doc comment.
    - **A signal sent as fast as the test could send it.** A press before the prompt goes out reaches a disposition the binary has not replaced yet, and one after the turn ends reaches nothing; either lets a broken binary pass. `CLISignals.readiness` polls the stub agent's own transcript for the `session/prompt` line first, which is a fact only a STARTED turn can produce.

    Both integration rows were checked by mutation, and both caught it:

    - `session/cancel` removed from `.cancelTurn`: the three one-press tests each failed with the 10-second run bound, and the two-press test still passed.
    - the throw removed from `.endRunAtOnce`: the two-press test failed with the same bound, and the three one-press tests still passed.

    Interfaces that moved:

    - `TurnRunner.init` takes `interrupts: AsyncStream<TurnInterrupt>? = nil`, in the same defaulted shape as `limit`, so no other caller changed.
    - `AcpClientExitCode.forError(_:)` reads `AcpClientInterrupted` before it asks ArgumentParser, beside the row `AcpClientTimeout` already had.
    - `ScriptedStubAgent` gained `cancelScript`, `makeNeverIdleAgent` gained `transcript`, and `StubAgents` gained `makeCancelAwareAgent`, `transcriptHolds(_:method:)` and a `.afterCancel` turn end. The read-until-a-line loop that `permissionExchangeStatements` already carried is now the shared `waitForLineStatements(holding:into:)`, so the cancel wait is not a second copy of it.
    - `AcpClientCore` took NO new dependency: `Darwin`, `Dispatch` and `Synchronization` are the platform and the standard library, so `ManifestTests` still pins five.
  timestamp: 2026-09-05T02:20:21.775217+00:00
- actor: claude-code
  id: 01m1qnw27g927bfwedzv6q3m2r
  text: |-
    ### implement — changed
    - evidence: 9 files — new `Sources/AcpClientCore/InterruptHandler.swift`, new `Tests/FoundationModelsACPClientTests/InterruptHandlerTests.swift`, new `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/InterruptTests.swift`; edited `Sources/AcpClientCore/TurnRunner.swift`, `Sources/AcpClientCore/RunCommand.swift`, `Sources/AcpClientCore/ExitCode.swift`, `Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift`, `Tests/FoundationModelsACPClientTests/TurnRunnerTests.swift`, `IntegrationTests/.../Support/CLITestSupport.swift`, `IntegrationTests/.../Support/StubAgents.swift`. `timeout 420 swift test`: 212 tests in 16 suites passed, 0 warnings. `timeout 600 swift test --package-path IntegrationTests`: 72 tests in 11 suites passed, 0 warnings. Every acceptance row and every test row is ticked.
    - next: ready for `/review`.
  timestamp: 2026-09-05T02:20:28.784913+00:00
depends_on:
- 01M1MQHBX56XTYHFZR6K0E160T
- 01M1MPECJSM165NAWX5F3NKX9A
position_column: doing
position_ordinal: '80'
title: 'Handle Ctrl-C: cancel the turn, print what arrived, reap, and exit 4'
---
## What

`cli-plan.md` §11. `Ctrl-C` must not kill the process at once. The binary
sends `session/cancel`, waits for the `cancelled` stop reason, prints the text
that arrived, reaps the agent, and exits 4. A second `Ctrl-C` ends the run at
once, and it still reaps the agent.

> **Paths corrected during implementation.** This card was written against
> `Sources/acp-client/`, which today holds the `@main` type alone. Everything
> the binary does lives in `Sources/AcpClientCore/`, and the two paths below
> are the corrected ones.

Create `Sources/AcpClientCore/InterruptHandler.swift`:

- A `DispatchSourceSignal` on `SIGINT`, with the default disposition set to
  ignore first, so the signal reaches the source and does not kill the
  process.
- The first signal calls a `@Sendable () -> Void` first-interrupt callback; the
  second calls a second-interrupt callback. A counter guarded by a `Mutex`
  makes the two paths exact, so a fast double press cannot run the first
  callback twice.
- The handler restores the default `SIGINT` disposition when it is torn down,
  so it leaves no global state behind.

Edit `Sources/AcpClientCore/TurnRunner.swift`: the first interrupt sends
`ClientSideConnection.sessionCancel(_:)` for the live session and keeps
waiting for the `idle` `state_update`. A `cancelled` stop reason maps to exit
4 through `AcpClientExitCode.forStopReason(_:)`, which needs no change. The
second interrupt stops the wait, tears the agent down, and exits 4 at once.

Chunks that arrived before the cancel stay on stdout: §11 says the binary
prints the text that arrived.

## Acceptance Criteria

- [x] One `SIGINT` sends `session/cancel` and does not kill the binary.
- [x] The run then exits 4 on the `cancelled` stop reason.
- [x] The stdout bytes hold the chunks that arrived before the cancel.
- [x] A second `SIGINT` ends the run at once and still exits 4.
- [x] The agent pid is gone after both paths.
- [x] With no interrupt, the handler changes nothing about a normal run.

## Tests

- [x] New `Tests/FoundationModelsACPClientTests/InterruptHandlerTests.swift`.
      It drives `InterruptHandler` with injected signal deliveries rather than
      real `SIGINT`, and asserts the first and second callbacks each run one
      time, in order, under a fast double delivery.
- [x] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/InterruptTests.swift`.
      Extend `StubAgents` with an agent that sends one chunk, then waits for
      `session/cancel`, then sends a `state_update` with the `cancelled` stop
      reason. The test spawns `acp-client`, sends `SIGINT` to it, and asserts
      exit 4 and the partial stdout.
- [x] One test uses an agent that ignores `session/cancel`, sends two
      `SIGINT` signals, and asserts exit 4 and that the agent pid is gone.
- [x] One test asserts a normal run with no signal still exits 0.
- [x] Run `swift test` and `swift test --package-path IntegrationTests`. Every
      assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.