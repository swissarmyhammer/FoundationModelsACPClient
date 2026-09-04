---
assignees:
- claude-code
depends_on:
- 01M1MQHBX56XTYHFZR6K0E160T
- 01M1MPECJSM165NAWX5F3NKX9A
position_column: todo
position_ordinal: '9080'
title: 'Handle Ctrl-C: cancel the turn, print what arrived, reap, and exit 4'
---
## What

`cli-plan.md` §11. `Ctrl-C` must not kill the process at once. The binary
sends `session/cancel`, waits for the `cancelled` stop reason, prints the text
that arrived, reaps the agent, and exits 4. A second `Ctrl-C` ends the run at
once, and it still reaps the agent.

Create `Sources/acp-client/InterruptHandler.swift`:

- A `DispatchSourceSignal` on `SIGINT`, with the default disposition set to
  ignore first, so the signal reaches the source and does not kill the
  process.
- The first signal calls a `@Sendable () -> Void` first-interrupt callback; the
  second calls a second-interrupt callback. A counter guarded by a `Mutex`
  makes the two paths exact, so a fast double press cannot run the first
  callback twice.
- The handler restores the default `SIGINT` disposition when it is torn down,
  so it leaves no global state behind.

Edit `Sources/acp-client/TurnRunner.swift`: the first interrupt sends
`ClientSideConnection.sessionCancel(_:)` for the live session and keeps
waiting for the `idle` `state_update`. A `cancelled` stop reason maps to exit
4 through `AcpClientExitCode.forStopReason(_:)`, which needs no change. The
second interrupt stops the wait, tears the agent down, and exits 4 at once.

Chunks that arrived before the cancel stay on stdout: §11 says the binary
prints the text that arrived.

## Acceptance Criteria

- [ ] One `SIGINT` sends `session/cancel` and does not kill the binary.
- [ ] The run then exits 4 on the `cancelled` stop reason.
- [ ] The stdout bytes hold the chunks that arrived before the cancel.
- [ ] A second `SIGINT` ends the run at once and still exits 4.
- [ ] The agent pid is gone after both paths.
- [ ] With no interrupt, the handler changes nothing about a normal run.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/InterruptHandlerTests.swift`.
      It drives `InterruptHandler` with injected signal deliveries rather than
      real `SIGINT`, and asserts the first and second callbacks each run one
      time, in order, under a fast double delivery.
- [ ] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/InterruptTests.swift`.
      Extend `StubAgents` with an agent that sends one chunk, then waits for
      `session/cancel`, then sends a `state_update` with the `cancelled` stop
      reason. The test spawns `acp-client`, sends `SIGINT` to it, and asserts
      exit 4 and the partial stdout.
- [ ] One test uses an agent that ignores `session/cancel`, sends two
      `SIGINT` signals, and asserts exit 4 and that the agent pid is gone.
- [ ] One test asserts a normal run with no signal still exits 0.
- [ ] Run `swift test` and `swift test --package-path IntegrationTests`. Every
      assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.