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
