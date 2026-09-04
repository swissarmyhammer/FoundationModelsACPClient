---
assignees:
- claude-code
depends_on:
- 01M1MPB4MKQH0Z50EH2DDJHW3G
- 01M1MPECJSM165NAWX5F3NKX9A
- 01M1MQEQYES0VD3F76KB55RRZ5
position_column: todo
position_ordinal: 8c80
title: 'Doctor checks 1 and 2: the command resolves, and the process starts and stays'
---
## What

`cli-plan.md` §10, the `Doctorable` scaffolding and the first two rows of the
check table. The protocol, the runner and the plain renderer come from
`FoundationModelsExtras`, under
`Sources/FoundationModelsExtras/Doctor/`. This package writes one conformance
over an agent command; it writes no doctor framework.

Create `Sources/acp-client/AgentCommandDoctor.swift`:

- `struct AgentCommandDoctor: Doctorable`. It holds the raw agent command, its
  arguments, an `AgentCommandResolver`, and a time limit that belongs to the
  doctor alone and is **not** shared with `--timeout`.
- The protocol's members are `doctorName` and `doctorCategory`, and
  `func runHealthChecks() async -> [HealthCheck]` is **not** throwing. Read
  `Doctorable.swift` before writing the conformance, and use the exact names.
  `doctorName` is the agent command as the person typed it; `doctorCategory` is
  one constant every check shares.
- `runHealthChecks()` runs the checks in order and skips the later ones when an
  earlier one made them meaningless: a command that does not resolve cannot be
  started. A skipped check is reported, not omitted, so the report always has
  the same shape.

The two checks of this task:

1. **The command resolves.** Run `AgentCommandResolver.resolve(_:)`. Each
   `AgentCommandResolutionFailure` case becomes an `error` check whose `fix`
   text names the mistake: a typing mistake, or a binary that was not built.
2. **The process starts, and it does not exit at once.** Spawn with
   `AgentProcess`, wait a short settle interval, and read
   `AgentProcess.processIdentifier`. An agent that is gone is an `error`, and
   the `fix` names a missing runtime or a crash on start. Tear the process
   down whatever the outcome.

Checks 3 to 7 all need a live ACP connection, so they belong to the two
following tasks.

## Acceptance Criteria

- [ ] `AgentCommandDoctor` conforms to `Doctorable`, with `doctorName`,
      `doctorCategory` and a non-throwing `runHealthChecks()`.
- [ ] Every returned value is built with the Extras `ok`, `warning` and
      `error` factories.
- [ ] A command that is not on `PATH` gives one `error` check, and the later
      checks are reported as skipped rather than dropped.
- [ ] An agent that exits at once gives an `error` check on row 2.
- [ ] `wellBehavedAgent` gives `ok` on both rows.
- [ ] No agent process outlives `runHealthChecks()`, whatever the outcome.

## Tests

- [ ] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`.
      It drives `AgentCommandDoctor` directly, not through the binary, so each
      check is asserted on its own. Use the `StubAgents` helpers.
- [ ] One test per acceptance row above, asserting the check `name`, `status`
      and that `fix` is not empty for each `error`.
- [ ] Extend `StubAgents` with an agent that exits at once.
- [ ] One test records the spawned pid and asserts `kill(pid, 0)` reports the
      process is gone after `runHealthChecks()`.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.