---
comments:
- actor: claude-code
  id: 01m21kfwwscfnkmqn8ct37n4rm
  text: |-
    Picked up. Research done.

    **What the code already gives, row by row.**

    - `--timeout` and exit 124: `SharedOptions.turnLimit` parses the option, `TurnRunner.run()` adds the limit as a child of the turn's task group and throws `AcpClientTimeout`, and `AcpClientExitCode.forError` maps it to 124. Proven by `TurnRunnerTests.aTurnThatNeverGoesIdleEndsAtItsLimit` (unit) and `TimeoutTests.anAgentThatNeverGoesIdleExitsWithTheTimeoutCode` (integration, exit 124 against a stub that never goes idle).
    - The first and the second `Ctrl-C`: `InterruptHandler` arms `SIG_IGN` and a `DispatchSourceSignal`, `TurnRunner.applyInterrupts` sends `session/cancel` on the first press and throws `AcpClientInterrupted` on the second, and both reach exit 4. Proven by `InterruptTests` (one press exits 4 with the partial text on stdout; two presses end a run whose agent ignores the cancellation, exit 4).
    - Reap on every exit path: `RunCommand.runTurn` reaps in a `defer`, and `AgentProcess.shutdown()` runs `killpg` on the group the agent leads (`posix_spawnattr_setpgroup(0)`). Proven by pid: `RunCommandExitTests` (success, four endings), `NoLeakedAgentTests` (the failure paths and a grandchild), `TimeoutTests.noAgentProcessOutlivesATimeout`, and the two `InterruptTests` pid rows.

    **What the card asks for that no test proves yet.**

    1. "The `DispatchSourceSignal` handler body only sets a flag." NOT satisfied. The event handler body is `deliver(times: Int(created.data))`, which takes a `Mutex`, advances a counter and runs the callbacks. The card wants the body to set a flag and the work to run on a normal task.
    2. "The recording client shows a `session/cancel` reached the agent before the exit." `InterruptTests` proves it only by inference (the cancel-aware stub sends `idle/cancelled` only after the notification). The stub's transcript does NOT record the `session/cancel` line: `recordRequestStatement` runs in the main request loop, and the cancel wait is a second read loop (`waitForLineStatements`) that records nothing. A direct transcript assertion will be red until the wait loop records too.
    3. "A second `SIGINT` ends the run inside a short, named time limit." The two-press row rests on the default run bound of `runAcpClient` (10 s) and the suite backstop. No named bound, no elapsed-time assertion.
    4. "After the run, the agent's process group holds no live process." Every reaping row probes the pid with `kill(pid, 0)`. None probes the GROUP. `kill(-pgid, 0)` reaches any member of the group the agent leads, so a grandchild that recorded no pid is visible to it and not to the pid probe.

    **Design decided.**

    - `InterruptHandler`: the event handler body becomes one statement, `pendingInterrupts.add(created.data, ordering: .sequentiallyConsistent)`, on an `Atomic<UInt>`. The count is the flag, because a `DispatchSourceSignal` coalesces a fast double press into one event carrying `data == 2` (decision 2 of the file), and a Bool would read that as one press. A normal task, started in `start()` and held in `ArmedInterrupts`, drains the flag every `interruptPollInterval` (20 ms, named) and calls `deliver(times:)`; `stop()` cancels it under the same lock as the source. `deliver(times:)` keeps the counting under the lock, and it delivers exactly `count` times because the drain never calls it with zero.
    - A source-level unit test reads `Sources/AcpClientCore/InterruptHandler.swift`, takes the body of `setEventHandler { ... }`, and asserts one statement that stores into the flag and no other call. It is red on the current code.
    - A unit row in `InterruptDispositionTests` sends a real `SIGINT` to the test process while a handler is armed and waits for the first callback, so the flag-and-drain path is proven without the integration suite.
    - Integration: `waitForLineStatements` learns the transcript, so the cancel line is recorded; `InterruptTests` asserts `transcriptHolds(transcript, method: "session/cancel")` on the one-press row, and a named `secondInterruptRunBudget` with an elapsed-time assertion on the two-press row. A `processGroupHasLiveMember(ledBy:)` helper (`kill(-pgid, 0)`) joins `processExists`, and one shared assertion helper checks the pid AND the group on the success, failure, timeout and interrupt reaping rows.
    - `AcpClientCore` takes no new dependency: `Synchronization` is the standard library, so `ManifestTests` still pins five.
  timestamp: 2026-09-08T22:51:17.273909+00:00
- actor: claude-code
  id: 01m21m10x040rmktb0wk198kyr
  text: |-
    Implementation landed. Notes for the next reader.

    **The one production change: `InterruptHandler` now sets a flag in the event handler and does the work on a drain task.**

    - The `DispatchSourceSignal` event handler body is one statement, `self.pendingInterrupts.add(created.data, ordering: .sequentiallyConsistent)`, on an `Atomic<UInt>`. The flag is a COUNT and not a `Bool`: a dispatch signal source coalesces a fast double press into one event carrying `data == 2` (decision 2 of the file), and a `Bool` would read that as one press.
    - `start()` begins a `Task` that reads the flag every `interruptPollInterval` (20 ms, named) with `exchange(0)`, hands the count to `deliver(times:)`, and sleeps. `stop()` cancels it under the same `Mutex` as the source and the disposition (`ArmedInterrupts` gained a `drain` member), so decision 5 still holds: one value, one lock, no writable split.
    - `deliver(times:)` now delivers exactly `count` times and guards zero, because the drain calls it with whatever the flag held and a round that found nothing owes nothing. The `smallestDeliveryCount` clamp went with the event-handler call it served.
    - `TurnRunner`, `RunCommand`, `ExitCode`: untouched. `AcpClientCore` took no new dependency; `Synchronization` is the standard library, and `ManifestTests` still pins five.

    **Each test was watched to fail first, or is a characterization row that guarded the refactor.**

    - `InterruptHandlerSourceTests` (new): reads `Sources/AcpClientCore/InterruptHandler.swift`, takes the body of the `setEventHandler { ... }` closure by counting braces, drops blank and comment lines, and asserts ONE statement that opens `self.pendingInterrupts.add(` and holds one `(`. RED on the old body — it reported `["[self] in", "deliver(times: Int(created.data))"]` — and GREEN on the new one. The `self.` is the explicit form an escaping closure of a class writes in place of a `[self]` capture clause, which would be a second line.
    - `InterruptDispositionTests` gained "a real SIGINT reaches the first callback while the handler is armed": arms a handler, sends `kill(getpid(), SIGINT)`, and waits with `eventually` for the first callback. It passed on the old code (it is a characterization row) and it passed on the new code, so the flag-and-drain path is proven in the unit target without the integration suite. `withDefaultInterruptDisposition` became `async` for it, and the three rows that use it now `await` it.
    - `InterruptTests` one-press row: `transcriptHolds(transcript, method: "session/cancel")`. RED — exit 4 held, and the transcript had no cancel line, because the stub's cancel wait was a second read loop (`waitForLineStatements`) that recorded nothing. GREEN after `waitForLineStatements` learned `appendingTo:` and `recordRequestStatement` learned which shell variable to append; `requestLoop`, `permissionExchangeStatements`, `cancelWaitStatements` and `turnEndStatements` thread `transcript` through. The permission wait records too, so the transcript holds every line that reached the agent, whichever loop read it.
    - `InterruptTests` two-press row: `secondInterruptRunBudget` (2 s, named) with an elapsed-time assertion around the whole run. Measured 0.071 s. Green at once, which is the behaviour the earlier card landed; the bound is now stated rather than inherited from `runAcpClient`.
    - `processGroupHasLiveMember(ledBy:)` in `Support/TransportTestSupport.swift` reads `kill(-pgid, 0)`, which reaches any member of the group the agent leads. `expectAgentGroupIsGone(ledBy:after:sourceLocation:)` in `Support/StubAgents.swift` checks the pid AND the group, and it stands on the success (`RunCommandExitTests`, four endings), failure (`NoLeakedAgentTests`, every scenario and the failed-spawn row), timeout (`TimeoutTests`) and interrupt (`InterruptTests`, both rows) reaping rows. The probe is held in BOTH directions at the seam the plan names: `AgentProcessTests.agentChildProcessIsCleanedUpWithTheGroup` asserts it reaches the live group before `shutdown()` and reaches nothing after, so a probe that answered `false` for a live group cannot pass.

    **Runs.**

    - `timeout 900 swift test`: 229 tests in 21 suites passed, 0 warnings (was 224 in 20).
    - `timeout 900 swift test --package-path IntegrationTests`: 92 tests in 13 suites passed, 0 warnings. No stray `acp-client` or stub process after the run.

    **What did NOT work, so nobody repeats it.**

    - A source test that counts every non-comment line of the closure body reads a `[self] in` capture clause as a statement. The fix is not to teach the test about capture clauses; it is to write the body without one, which the explicit `self.` does. The test's own doc says so.
    - The `async` helper was the only way to keep one `withDefaultInterruptDisposition` for the four disposition rows. A second sync copy would have been a duplicate, and a spin-wait would have been a second poll loop beside `eventually`.

    **Discoveries.**

    - `Atomic<UInt>.add(_:ordering:)` is `@discardableResult`, so the store stands alone as the one statement with no `_ =` in front of it.
    - The stub agent's cancel wait never recorded what it read. Every earlier `InterruptTests` row passed on inference (the cancel-aware agent only sends `idle/cancelled` after the notification); the transcript now states it.
    - `cli-plan.md` §11 describes no handler internals, so no document changed. Decision 7 at the head of `InterruptHandler.swift` is where the flag-and-drain design is recorded.
  timestamp: 2026-09-08T23:00:38.432780+00:00
- actor: claude-code
  id: 01m21m1cqtr4r2s5qe3yztcg7p
  text: |-
    ### implement — changed
    - evidence: 10 files — edited `Sources/AcpClientCore/InterruptHandler.swift` (the event handler body is one store into an `Atomic<UInt>` flag, and a drain task started in `start()` and cancelled in `stop()` carries the count to `deliver(times:)`); new `Tests/FoundationModelsACPClientTests/InterruptHandlerSourceTests.swift` (source-level: the `setEventHandler` body is one statement, the store into the flag, and no other call; red on the old body, green now); edited `Tests/FoundationModelsACPClientTests/InterruptHandlerTests.swift` (a real `SIGINT` to the test process reaches the first callback; the disposition helper is `async`); edited `IntegrationTests/.../InterruptTests.swift` (the transcript holds `session/cancel` on the one-press row, red until the stub recorded its cancel wait; `secondInterruptRunBudget` of 2 s on the two-press row); edited `IntegrationTests/.../Support/StubAgents.swift` (`waitForLineStatements` records to the transcript; `expectAgentGroupIsGone(ledBy:after:)`); edited `IntegrationTests/.../Support/TransportTestSupport.swift` (`processGroupHasLiveMember(ledBy:)`, `kill(-pgid, 0)`); edited `IntegrationTests/.../AgentProcessTests.swift` (the group probe held true before and false after the teardown), `RunCommandExitTests.swift`, `TimeoutTests.swift`, `NoLeakedAgentTests.swift` (the pid-and-group assertion on the success, timeout and failure reaping rows). `timeout 900 swift test`: 229 tests in 21 suites passed, 0 warnings. `timeout 900 swift test --package-path IntegrationTests`: 92 tests in 13 suites passed, 0 warnings. Every subtask, acceptance row and test row of the card is ticked.
    - next: ready for `/review`.
  timestamp: 2026-09-08T23:00:50.554861+00:00
position_column: doing
position_ordinal: '80'
title: 'N6: --timeout, the interrupt, and the reaping proofs'
---
## What

Milestone **N6** of this repository's `cli-plan.md` §11.

Asked for by `FoundationModelsACPAgent`, card `^btrrzav`.

- `--timeout <seconds>`: end the run if the turn does not stop in time,
  and exit 124, the `timeout(1)` convention.
- `Ctrl-C`: send `session/cancel`, wait for the `cancelled` stop reason,
  print the text that arrived, reap the agent, exit 4. A second `Ctrl-C`
  ends the run at once, and it still reaps the agent.
- Use a `DispatchSourceSignal`, and do the work on a normal task. The
  handler body only sets a flag, because a signal handler must be
  async-signal-safe.

**The obligation this card exists for: no agent process outlives the
run.** This holds after success, after a failure, after a timeout, and
after an interrupt. `AgentProcess` already spawns the agent in its own
process group; this card proves the reaping.

A leaked agent holds gigabytes of model weights, so each exit path gets
its own test.

- [x] `--timeout`, and exit 124
- [x] The first and the second `Ctrl-C`
- [x] Reap the agent in every exit path

## Acceptance Criteria

- [x] A turn that runs past `--timeout` exits 124.
- [x] A `SIGINT` during a turn exits 4, and the partial text is on
      stdout.
- [x] A second `SIGINT` ends the run inside a short, named time limit.
- [x] After each of success, failure, timeout and interrupt, no process
      in the agent's process group is alive.
- [x] The `DispatchSourceSignal` handler body only sets a flag.

## Tests

- [x] A timeout test against a stub that never finishes: exit 124.
- [x] An interrupt test: exit 4, and the recording client shows a
      `session/cancel` reached the agent before the exit.
- [x] A second-interrupt test with a time bound.
- [x] One reaping test per exit path: after the run, the agent's process
      group holds no live process.
- [x] A source-level test that the signal handler body sets a flag and
      calls nothing else.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.