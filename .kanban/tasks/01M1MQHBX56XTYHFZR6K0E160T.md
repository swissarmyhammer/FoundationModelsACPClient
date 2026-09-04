---
assignees:
- claude-code
depends_on:
- 01M1MPFEP97Z6J3R0MRC6XXKAJ
- 01M1MPARCGY1FHKNED47MDBWG8
- 01M1MPB4MKQH0Z50EH2DDJHW3G
- 01M1MPC2YVFK0A9NX4T9H4M0EV
- 01M1MPECJSM165NAWX5F3NKX9A
position_column: todo
position_ordinal: '9680'
title: 'Wire RunCommand: spawn the agent, run the turn, and exit with the right code'
---
## What

Join the pieces into the default subcommand. `TurnRunner` holds no process
handling by design, so this task owns the `AgentProcess` and the exit.

Edit `Sources/acp-client/RunCommand.swift`:

- Resolve the agent command through `AgentCommandResolver`, so a bare name and
  a relative path both reach `AgentProcess` as the absolute path it demands.
- Resolve the prompt through `PromptSource`. The
  `noPromptAndStdinIsATerminal` failure becomes the usage text on stderr and
  exit 2, with stdout untouched.
- Construct `AgentProcess`, build an `AgentSession` over its transport, and
  run a `TurnRunner` with `answerSink` pointed at stdout.
- Exit through `AcpClientExitCode`: `forStopReason(_:)` for a
  `.stopped(reason)` outcome, `success` for `.idleWithNoReason`, and
  `forError(_:)` for a spawn, protocol or I/O failure.
- **Tear the agent down on every path**, in a `defer`, so success, failure and
  a thrown error all reap it. `AgentProcess.shutdown()` is idempotent.

No file in `Sources/acp-client/` outside `ExitCode.swift` may hold a bare
numeric exit literal; this is the task that makes that true, and
`ExitCodeTests` asserts it.

## Acceptance Criteria

- [ ] `acp-client run "hi" -- <wellBehavedAgent>` writes the answer to stdout
      and exits 0.
- [ ] A `refusal` stop reason exits 3, and a `cancelled` one exits 4.
- [ ] An `idle` with no stop reason exits 0.
- [ ] A command that is not on `PATH` exits 1 with an explanatory stderr line
      and an empty stdout.
- [ ] No prompt with stdin a terminal exits 2, with an empty stdout.
- [ ] The agent pid is gone after every one of those exits.

## Tests

- [ ] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/RunCommandExitTests.swift`,
      one test per acceptance row above, through `runAcpClient(_:)`.
- [ ] Extend `StubAgents` with agents that end their turn with `refusal`,
      with `cancelled`, and with an `idle` that carries no `stopReason`.
- [ ] One test writes the agent pid to a pid file, waits for each exit, and
      asserts `kill(pid, 0)` reports the process is gone.
- [ ] One test asserts the §7 prompt rows through the real binary: an
      argument, a piped stdin, and `-`.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.