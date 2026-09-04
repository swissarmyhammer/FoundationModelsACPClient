---
assignees:
- claude-code
depends_on:
- 01M1MQHBX56XTYHFZR6K0E160T
- 01M1MPECJSM165NAWX5F3NKX9A
position_column: todo
position_ordinal: 8f80
title: 'Add --timeout: end the run at the limit, exit 124, and reap the agent'
---
## What

`cli-plan.md` §6.1 and §9. `--timeout <seconds>` ends the run when the turn
does not stop in time. The default is no limit. Exit code 124 is the
`timeout(1)` convention.

Edit `Sources/acp-client/TurnRunner.swift` and
`Sources/acp-client/RunCommand.swift`:

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

- [ ] With no `--timeout`, a slow agent still runs to its stop reason.
- [ ] With `--timeout`, an agent that never reaches `idle` ends the run at the
      limit and exits 124.
- [ ] The stdout bytes that arrived before the limit are still written.
- [ ] The agent pid is gone after the timeout exit.
- [ ] `--timeout 0` and a negative value give a usage error and exit 2.
- [ ] A run that finishes inside the limit exits with its stop reason's code,
      and not 124.

## Tests

- [ ] Extend `Tests/FoundationModelsACPClientTests/ExitCodeTests.swift` with
      an assertion that `forError(AcpClientTimeout())` is 124.
- [ ] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/TimeoutTests.swift`.
      Extend `StubAgents` with an agent that sends one chunk and then never
      sends `state_update`. One test per acceptance row above.
- [ ] One test asserts the partial stdout: the bytes equal the one chunk that
      arrived.
- [ ] One test records the agent pid, waits for the 124 exit, and asserts
      `kill(pid, 0)` reports the process is gone.
- [ ] Run `swift test` and `swift test --package-path IntegrationTests`. Every
      assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.