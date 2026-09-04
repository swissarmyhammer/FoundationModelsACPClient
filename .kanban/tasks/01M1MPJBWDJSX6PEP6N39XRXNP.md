---
assignees:
- claude-code
depends_on:
- 01M1MQQ5T3KQWESKQ2AT3Y93W4
- 01M1MPC2YVFK0A9NX4T9H4M0EV
- 01M1MPARCGY1FHKNED47MDBWG8
position_column: todo
position_ordinal: '8e80'
title: 'Implement the doctor subcommand: render the report, --json, and exit 0, 1 or 5'
---
## What

`cli-plan.md` §10 and §9. `probe` says what an agent supports; `doctor` says
whether it is usable, and its exit code carries the verdict.

Edit `Sources/acp-client/DoctorCommand.swift`:

- Build one `AgentCommandDoctor` over the given command, and run it through
  `FoundationModelsExtras.DoctorRunner`, which gives a `DoctorReport`.
- Write the report to **stdout**. §8 makes `doctor` an exception to the stdout
  rule, because its report is its output. The plain form comes from
  `PlainTextDoctorRenderer`; pass `useColor` true only when stdout is a
  terminal. `--json` writes `DoctorReport.jsonData(prettyPrinted:)` instead.
- Exit through `AcpClientExitCode.forDoctorStatus(report.worstStatus)`: 0 for
  `ok`, 5 for `warning`, 1 for `error`. Do **not** use
  `DoctorReport.exitCode`, which is the Extras convention: §9 says code 5
  exists here because the Rust doctor's code 2 for errors would collide with
  this binary's usage error. Write that reason as a comment at the call site,
  so a later reader does not "simplify" it back.

## Acceptance Criteria

- [ ] `acp-client doctor -- <wellBehavedAgent>` prints a report to stdout and
      exits 0.
- [ ] `acp-client doctor -- <bannerOnStdoutAgent>` reports that row as an
      error and exits 1.
- [ ] `acp-client doctor -- <silentAgent>` reports a timeout, not a hang, and
      exits 1.
- [ ] An agent whose worst status is `warning` exits 5, and never 2.
- [ ] `acp-client doctor -- does-not-exist` exits 1 and names the command.
- [ ] `--json` writes valid JSON to stdout, holding one entry per check with
      its name, status, message and fix.
- [ ] A usage error still exits 2, so 2 and 5 never collide.

## Tests

- [ ] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/DoctorCommandTests.swift`,
      one test per acceptance row above, driving the real binary through
      `runAcpClient(_:)`.
- [ ] One test parses the `--json` output with `JSONSerialization` and asserts
      the check entries hold a non-empty `fix` for every `error` status.
- [ ] One test runs `acp-client doctor` with no `--` and asserts exit 2, which
      pins that the doctor codes and the usage code stay apart.
- [ ] One test asserts the plain-text report holds a line for every check the
      §10 table names.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.