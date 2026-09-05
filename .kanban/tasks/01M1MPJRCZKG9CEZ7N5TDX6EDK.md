---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1qhkj3zjhdmfp832h834mz4
  text: |-
    Research done. Card paths corrected: the CLI code moved to `Sources/AcpClientCore/`, not `Sources/acp-client/`. The two files the card names are `Sources/AcpClientCore/TurnRunner.swift` and `Sources/AcpClientCore/RunCommand.swift`. `Sources/acp-client/` now holds only the thin `@main` (task ^m83zshz split it).

    What is already in place:
    - `SharedOptions.timeout: Double?` parses today; no subcommand reads it.
    - `AcpClientTimeout` and `AcpClientExitCode.timeout = 124` exist in `Sources/AcpClientCore/ExitCode.swift`, and `forError(_:)` maps the marker to 124.
    - `ExitCodeTests.theTimeoutMarkerIsTheTimeoutExitCode()` already asserts `forError(AcpClientTimeout()) == .timeout`, and `everyExitCodeCarriesItsSectionNineNumber()` pins `.timeout` at 124. The "Tests" checkbox that asks for that assertion is therefore already served.

    Design decision, and why it departs from the doctor's shape in one detail:
    `AgentCommandDoctor.initializeOutcome(of:)` races one `initialize` against a limiter task and reads a `CancellationError` as "the limit ended first". That reading is sound there because the raced work is ONE `Connection.call`, which fails a cancelled request with `CancellationError` at once. It is NOT sound for the turn: `TurnRunner.run()` is a `withThrowingTaskGroup` of three children, and by the moment a limit lands the prompt request has usually already been answered — so cancelling the group makes `readTurn` return `nil` and `run()` throws `TurnEndedWithoutIdleError`, not `CancellationError`. Reading the error type would be a race.

    So the limit becomes a FOURTH child of that same task group: it sleeps for the limit and then throws `AcpClientTimeout`. The group is the race, the throw is deterministic, and `withThrowingTaskGroup` cancels and drains the other three children on the way out — which is the same "cancel the pending request rather than abandon it" property the doctor's shape buys.

    `--timeout 0` and a negative value: validated in `SharedOptions.validate()`. ArgumentParser calls `validate()` on every `@OptionGroup` value (`OptionGroup.init(from:)`), and wraps the throw as `ParserError.userValidationError`, which `AcpClient.processExitCode(for:)` already turns into 2. One place, and it holds for `run`, `probe` and `doctor` alike — a value that means nothing is a mistake wherever it is typed.

    `probe` stays unbounded. The card names `run` alone, and the reasoning of ^39xrxnp holds: `probe` runs no turn, so the turn's limit has nothing to bound there.

    No new dependency: `AcpClientTimeout` and `Duration` are both already reachable. `ManifestTests` stays at five.
  timestamp: 2026-09-05T01:05:55.839320+00:00
- actor: claude-code
  id: 01m1qjbfga02zdcthcadn4v0wd
  text: |-
    Implementation landed, TDD throughout.

    **RED, and what it proved.** The two new unit tests failed first, and the never-idle one failed in exactly the way the research comment predicted: `Expectation failed: expected error of type AcpClientTimeout, but "The agent's update stream ended before the agent reported that it was idle." of type TurnEndedWithoutIdleError was thrown instead`. The swift-testing time limit cancelled the task, the group's reader ended its stream, and `run()` threw `TurnEndedWithoutIdleError`. That is the race a limiter task racing from outside would have had to read as "the limit ended first", and it settles the design: the limit is a FOURTH CHILD of the turn's own task group, which sleeps and then throws `AcpClientTimeout`. Rule 5 at the head of `TurnRunner.swift` records the whole reasoning, and names `AgentCommandDoctor` as the place where the outside race IS sound and why.

    **One correction to the earlier comment.** It named the library-split task as `^m83zshz`. The `short_id` is `^w83zshz`. The description now carries the correct one.

    **A conflict this raised, and how it was answered.** `SharedOptions.validate()` holds for `run`, `probe` and `doctor` alike, so `doctor --timeout 0` became exit 2. That broke the existing `DoctorCommandTests."--timeout never becomes the doctor's own limit"`, which drove `--timeout 0` and `--timeout=-1` and expected a passing report. The test's INTENT — the doctor keeps a limit of its own — is unharmed; only its probe values became illegal to type. They were chosen because zero collapses every interval the doctor makes. The smallest legal value does the same: the two rows now drive `0.001`, in both spellings of the option, and a leak at one millisecond still fails the initialize row. `Support/TimeoutOption.swift` holds that value and the option name, with the reasoning, because two suites now drive the option for opposite reasons.

    **What was extracted, and what was left for a follow-up.**
    - `SectionNineExitCode` moved out of `RunCommandExitTests.swift` into `Support/SectionNineExitCode.swift`, internal, with the 124 row added. No call site changed. A third copy of the §9 numbers in the new file was the alternative, and it is what the duplication rule forbids.
    - `runArguments(prompt:options:script:)` is new in `Support/StubAgents.swift`, extracted from the changed code as the duplication rule directs. The two private near-copies in `RunCommandExitTests` and `StreamRulesTests` were NOT edited: that rule says the counterpart is a separate piece of work. Filed as ^cen6s76.

    **Stub agents.** `requestLoop` gained a `turnEnd: StubAgentTurnEnd` parameter defaulting to `.atOnce`, so no existing call site changed. `makeNeverIdleAgent(answer:pidFile:)` streams one chunk and then sends no `state_update` at all; `makeSlowTurnAgent(answer:stopReason:delaySeconds:pidFile:)` streams the chunk, sleeps, and then ends the turn. One agent serves both `--timeout` readings, so the slow-agent tests differ in the option alone.

    **Tests.** Both suites run green with zero failures and zero warnings:
    - `timeout 420 swift test` — 204 tests in 15 suites.
    - `timeout 600 swift test --package-path IntegrationTests` — 66 tests in 10 suites.

    `ManifestTests` still holds `AcpClientCore` at five dependencies; nothing new was linked.
  timestamp: 2026-09-05T01:18:59.594348+00:00
- actor: claude-code
  id: 01m1qjbnkcprw4yz5310smx9er
  text: |-
    ### implement — changed
    - evidence: 11 files. Production: Sources/AcpClientCore/TurnRunner.swift, Sources/AcpClientCore/SharedOptions.swift, Sources/AcpClientCore/RunCommand.swift. Unit tests: Tests/FoundationModelsACPClientTests/TurnRunnerTests.swift, Tests/FoundationModelsACPClientTests/CommandParsingTests.swift. Integration tests: IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/TimeoutTests.swift (new), Support/SectionNineExitCode.swift (new), Support/TimeoutOption.swift (new), Support/StubAgents.swift, RunCommandExitTests.swift, DoctorCommandTests.swift. `timeout 420 swift test` — 204 tests in 15 suites, all passing, zero warnings. `timeout 600 swift test --package-path IntegrationTests` — 66 tests in 10 suites, all passing, zero warnings. Every acceptance row and every test row of the description is checked; no row was left open.
    - next: /review
  timestamp: 2026-09-05T01:19:05.836925+00:00
- actor: claude-code
  id: 01m1qjxt06vfjdprfqft6k78ys
  text: |
    ### review — findings
    - evidence: `review sha 714f53b~1..714f53b`, 11 files, 7 validators — engine counts 0 findings / 0 confirmed / 0 refuted. One finding comes from the driver's own measurement of the five judgement points: Sources/AcpClientCore/TurnRunner.swift:201.
    - The five points, and how each was settled:
      1. Task group shape — SETTLED BY MEASUREMENT, and correct. A model of the outer-race shape throws `TurnEndedWithoutIdleError`, because `readTurn` loops over an `AsyncStream` that cancellation finishes, so it returns `nil` and throws nothing. The fourth-child shape leaks no task: the timeout path lets `withThrowingTaskGroup` cancel and await every child before the throw leaves, and the normal path calls `group.cancelAll()` before it returns, so the pending sleep ends at once (return measured at 0.39 ms with a 5 s sleep child pending).
      2. §8 stdout bytes — SETTLED BY MEASUREMENT. `swift test --package-path IntegrationTests --filter TimeoutTests`: 6 tests passed. The assertion is byte EQUALITY against the one chunk, which pins both halves at one time. The error line goes to stderr, and the thrown `ExitCode` prints an empty message.
      3. §11 real pid — SETTLED BY MEASUREMENT. The pid comes from a file the `/bin/sh` agent writes with `$$`, and the probe is `kill(pid, 0)`. One check with no poll is sound, because `AgentProcess` teardown does `killpg` and then a BLOCKING `waitpid` before `acp-client` exits.
      4. Zero and negative `--timeout` — SETTLED BY MEASUREMENT on the built binary. `run`, `probe` and `doctor` each give exit 2 for `0`, `-1` and `-0.5`. 64 never reaches the process: `AcpClient.main()` does not use ArgumentParser's `main()`; it catches the error, keeps ArgumentParser as the classifier, and `processExitCode(for:)` turns a `.validationFailure` into `AcpClientExitCode.usage` = 2. A legal `0.001` passes validation and goes on to run.
      5. The changed doctor test — SETTLED BY READING. `0.001` keeps the full discriminating power. If the doctor took `--timeout` as its own limit, two independent rows would still break, and both stand far above one millisecond: the initialize race would cancel a `/bin/sh` spawn plus a round trip, and the teardown watch would give the process group 1 ms to empty. The old `0` collapsed the settle watch as well, but that arm never discriminated, because a well-behaved agent has a pid at once. Both spellings of the option are still covered.
    - The finding, in short: the fourth child is always pending, so the loop can never fall through to `throw TurnEndedWithoutIdleError()`. An agent that goes away in the middle of the turn is then reported as a limit reached. Measured with a stub agent that streams one chunk, answers the prompt, and exits with no `state_update`: no `--timeout` gives exit 1 in 0.04 s with "The agent's update stream ended before the agent reported that it was idle."; `--timeout 5` gives exit 124 in 5.25 s with "The run reached the limit --timeout gave it, and ended." Both runs put the same partial bytes on stdout, so §8 holds on both.
    - next: /implement — end the turn when the reader gives `nil`, then re-review.
  timestamp: 2026-09-05T01:29:00.166900+00:00
- actor: claude-code
  id: 01m1qjys40r3gzfazedn9as5kx
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 11 files. The limit is a FOURTH child of `TurnRunner`'s task group. The card's stale `Sources/acp-client/` paths are corrected.
    - test: green — root 204 passed in 15 suites, integration 66 passed in 10 suites, 0 warnings on both
    - commit: 714f53b feat(cli): add --timeout to end the run at the limit, exit 124, and reap the agent
    - review: findings — Sources/AcpClientCore/TurnRunner.swift:201

    The review settled all five points I raised, four of them by measurement against the built binary:
    - The fourth-child shape is right, and the outer race the card suggested would NOT work. `readTurn` loops over an `AsyncStream`, and cancellation FINISHES that stream rather than throwing, so an outer race makes the reader return `nil` and the run reports `TurnEndedWithoutIdleError` in place of the timeout.
    - No task leaks. On the timeout path the group cancels and awaits every child before the throw leaves; on the normal path `group.cancelAll()` runs before the return, so the pending sleep ends at once.
    - §8 holds: the stdout assertion is byte EQUALITY against the single chunk, which pins both halves — the chunk is there and nothing stands beside it.
    - §11 holds against a real pid, and the single un-polled check is sound because teardown does `killpg` then a BLOCKING `waitpid` before the binary exits.
    - Exit 2 and never 64, measured for `run`, `probe` and `doctor` over `0`, `-1` and `-0.5`. `AcpClient` keeps its own `main()`, so ArgumentParser's 64 never reaches the process.
    - The changed doctor test keeps its power: two independent rows still break at 1 ms if the doctor ever adopted the option.

    The finding is a real regression this card introduced, measured against a stub that streams a chunk, answers the prompt, then exits with no `state_update`:
    - no `--timeout` → exit 1 in 0.04 s, "the update stream ended before the agent reported that it was idle"
    - `--timeout 5` → exit 124 in 5.25 s

    The fourth child is always pending, so the reader's `nil` hits `continue` and leaves the sleeping child as the only child left. An agent that goes away mid-turn is reported as a limit reached, and the run waits out the whole limit for nothing. A protocol failure lands in the §9 timeout row.
  timestamp: 2026-09-05T01:29:32.032864+00:00
- actor: claude-code
  id: 01m1qkfy6g25xx5qefnrpgzhx8
  text: |-
    Finding at `Sources/AcpClientCore/TurnRunner.swift:201` fixed, TDD throughout. The checklist item is now `- [x]`.

    **The cause, and why the suggested one-line fix was not enough.** The group's element type was `TurnOutcome?`, and THREE children finish with no outcome: the prompt acknowledgement, the spinner, and the reader when its stream ends. One `nil` cannot tell them apart, so `continue` was correct for two of them and wrong for the third. Making the reader's `nil` throw at that one call site would have worked, but it would have left the same trap in the file — the next child that returns `nil` gets the same wrong reading. So the element type now says WHICH child finished: `TurnEvent` with `turnEnded(TurnOutcome)`, `streamEndedWithoutIdle` and `sideWorkFinished`. The reader is the only child that can report either of the first two, and the loop reads each case for what it is. Rule 6 at the head of the file records the whole reasoning, the measurement, and what the shared `nil` cost.

    **Every property the review confirmed still holds.**
    - Timeout path: unchanged. The limit child still throws `AcpClientTimeout`, and `withThrowingTaskGroup` cancels and awaits every child before the throw leaves.
    - Normal path: `group.cancelAll()` still runs before the return, so a sleeping limit ends at once.
    - The new `streamEndedWithoutIdle` throw leaves the same way as the limit's: a throw out of the group body cancels and drains every other child, the sleeping limit among them.
    - §8: both new tests assert byte EQUALITY on the answer that arrived.
    - §11: `no agent process outlives a run that reached its limit` still passes.

    **RED, measured, before the fix.**
    - Unit: `expected error of type TurnEndedWithoutIdleError, but "The run reached the limit --timeout gave it, and ended." of type AcpClientTimeout was thrown instead` — after 5.238 s.
    - Integration: two issues — the exit code, and `elapsed → 5.253730959 seconds` against a 2 s budget.

    **GREEN, after.** The same two tests: 0.031 s and 0.032 s.

    **The new stub agent.** `StubAgentTurnEnd.byExiting` and `makeExitingMidTurnAgent(answer:pidFile:)` in `Support/StubAgents.swift`: one chunk, the prompt answer, then `exit 0` with no `state_update`. It is NOT the same agent as `makeNeverIdleAgent`, and the pair is what tells the two §9 rows apart — that one stays alive and says nothing, so its run really does run out of time; this one goes away, so its run owes the protocol failure at once. Both doc comments name the other.

    **The regression test asserts both halves at one time**, because the two are one defect: the exit code (`SectionNineExitCode.failure`, not `.timeout`) AND the elapsed time against `goingAwayRunBudget` of 2 s, under a `--timeout 5`. An assertion on the code alone would pass for a run that still waited five seconds for nothing.

    **One seam added to the unit harness.** `TurnRunnerHarness` now holds the agent's end of the in-memory pair and offers `agentGoesAway()`. No scripted update can stand in for an agent that exits: what the client sees is its incoming bytes ending, which ends its read loop and finishes every session update stream behind it. `ScriptedStubAgent` was not touched.
  timestamp: 2026-09-05T01:38:54.288717+00:00
- actor: claude-code
  id: 01m1qkjkwy0z4y9hpe071ar3tc
  text: |-
    ### implement — changed
    - evidence: 4 files. Production: Sources/AcpClientCore/TurnRunner.swift (the group's element becomes `TurnEvent`; the reader's stream ending now ends the turn). Unit test: Tests/FoundationModelsACPClientTests/TurnRunnerTests.swift (`an agent that goes away under a limit is a protocol failure`, plus `TurnText.unreachedLimit` and the harness seam `sendAgentAway()`). Integration: IntegrationTests/.../Support/StubAgents.swift (`StubAgentTurnEnd.byExiting`, `makeExitingMidTurnAgent(answer:pidFile:)`) and .../TimeoutTests.swift (`an agent that goes away mid-turn fails at once, and does not wait out the limit`).
    - red then green, the new regression test: unit RED `expected error of type TurnEndedWithoutIdleError, but ... AcpClientTimeout was thrown instead` after 5.238 s → GREEN 0.031 s. Integration RED 2 issues, exit 124 and `elapsed → 5.253730959 seconds` against the 2 s budget → GREEN 0.032 s. Both assert the exit code AND the elapsed time, because the wrong code and the wasted wait are one defect.
    - `timeout 420 swift test` — 205 tests in 15 suites, all passing. `timeout 600 swift test --package-path IntegrationTests` — 67 tests in 10 suites, all passing. `swift build --build-tests` on both packages: zero warnings.
    - The finding's checklist item is `- [x]`. The cause was removed from the whole file, not from the one line: the reported `continue` was correct for the two children that cannot end the turn and wrong only for the reader, so the element type now names which child finished.
    - next: /review
  timestamp: 2026-09-05T01:40:22.046105+00:00
depends_on:
- 01M1MQHBX56XTYHFZR6K0E160T
- 01M1MPECJSM165NAWX5F3NKX9A
position_column: doing
position_ordinal: '80'
title: 'Add --timeout: end the run at the limit, exit 124, and reap the agent'
---
## What

`cli-plan.md` §6.1 and §9. `--timeout <seconds>` ends the run when the turn
does not stop in time. The default is no limit. Exit code 124 is the
`timeout(1)` convention.

Edit `Sources/AcpClientCore/TurnRunner.swift` and
`Sources/AcpClientCore/RunCommand.swift`. This card first named
`Sources/acp-client/`, which went stale when task ^w83zshz split the CLI into
the `AcpClientCore` library and a thin `@main`; the paths are corrected here
during the implement step.

- When `--timeout` is absent, nothing changes: the run waits with no limit.
- When it is given, race the wait for the `idle` `state_update` against a
  sleep of that duration. The limit ends the run and throws
  `AcpClientTimeout`, which `AcpClientExitCode.forError(_:)` already maps
  to 124.
- The text that already arrived stays on stdout. A timeout is not a reason to
  discard the answer bytes the agent sent.
- The agent is torn down before the process exits, on the timeout path exactly
  as on every other path. A leaked agent holds gigabytes of model weights.
- A timeout value that is zero or negative is a usage error, exit 2.

The `--timeout` limit is the turn's limit, and it is a different thing from
the doctor's own time limit. Do not share one constant between them.

## Acceptance Criteria

- [x] With no `--timeout`, a slow agent still runs to its stop reason.
- [x] With `--timeout`, an agent that never reaches `idle` ends the run at the
      limit and exits 124.
- [x] The stdout bytes that arrived before the limit are still written.
- [x] The agent pid is gone after the timeout exit.
- [x] `--timeout 0` and a negative value give a usage error and exit 2.
- [x] A run that finishes inside the limit exits with its stop reason's code,
      and not 124.

## Tests

- [x] Extend `Tests/FoundationModelsACPClientTests/ExitCodeTests.swift` with
      an assertion that `forError(AcpClientTimeout())` is 124. It was already
      there — `theTimeoutMarkerIsTheTimeoutExitCode()` asserts the mapping and
      `everyExitCodeCarriesItsSectionNineNumber()` pins `.timeout` at 124 —
      so the row is served and nothing was added.
- [x] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/TimeoutTests.swift`.
      Extend `StubAgents` with an agent that sends one chunk and then never
      sends `state_update`. One test per acceptance row above.
- [x] One test asserts the partial stdout: the bytes equal the one chunk that
      arrived.
- [x] One test records the agent pid, waits for the 124 exit, and asserts
      `kill(pid, 0)` reports the process is gone.
- [x] Run `swift test` and `swift test --package-path IntegrationTests`. Every
      assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-04 20:28)

> Scope: `review sha 714f53b~1..714f53b` — the diffs only. 11 files reviewed.
> The engine pass ran 7 validators and gave zero findings. The item below
> comes from the driver's own measurement of the five judgement points, and
> not from a validator.

- [x] `Sources/AcpClientCore/TurnRunner.swift:201` `review/judgement` — With a limit set, an agent that goes away in the middle of the turn reports the limit instead of the protocol failure, and only after the full limit has passed. The fourth child is always pending, so the loop at lines 207 to 212 can never fall through to `throw TurnEndedWithoutIdleError()`: a `nil` from the reader goes to `continue`, and the sleeping child is then the only child that is left. Measured with a stub agent that streams one chunk, answers the prompt, and then exits with no `state_update`. With no `--timeout` the run exits 1 after 0.04 s, and stderr reads "The agent's update stream ended before the agent reported that it was idle." With `--timeout 5` the same agent gives exit 124 after 5.25 s, and stderr reads "The run reached the limit --timeout gave it, and ended." No limit was reached — the agent went away — so a protocol failure goes to the timeout row of §9, and the run waits the full limit for no reason. End the turn when the reader gives `nil`: make that `nil` throw `TurnEndedWithoutIdleError`, or count the children that can still end the turn and stop when no such child is left.
