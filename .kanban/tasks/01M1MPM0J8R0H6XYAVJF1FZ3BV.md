---
assignees:
- claude-code
depends_on:
- 01M1MPG0WT31XJVP37C3CAT35C
- 01M1MPJRCZKG9CEZ7N5TDX6EDK
- 01M1MPKCCB56CA910R6JA5XSFA
position_column: todo
position_ordinal: '9180'
title: Prove no agent process outlives the run, on every exit path
---
## What

`cli-plan.md` §11: "**No agent process outlives the run.** This holds after
success, after a failure, after a timeout, and after an interrupt. A leaked
agent holds gigabytes of model weights, so a test asserts each path."

The earlier tasks each assert their own path. This task makes the claim one
suite that walks every exit code of §9, so a later change to any path has one
place that goes red. It also covers the paths no earlier task owns: an agent
that dies in the middle of a turn, and a protocol failure.

Create
`IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/NoLeakedAgentTests.swift`:

- One helper that runs `acp-client` against a chosen stub, reads the agent pid
  from the pid file the stub writes, waits for the binary to exit, and asserts
  `kill(pid, 0)` reports the process is gone. It names the pid and the exit
  path in the failure message.
- Drive that helper for each row: exit 0 (`end_turn`), exit 1 (a protocol
  failure), exit 3 (`refusal`), exit 4 (an interrupt), exit 124 (a timeout),
  and the agent-died-mid-turn case.
- Also assert the grandchild case: a stub that spawns a child of its own is
  group-killed with its parent, which is what `POSIX_SPAWN_SETPGROUP` in
  `AgentProcess` buys. The existing
  `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentProcessTests.swift`
  already has a pid-file pattern for that; reuse it.

Extend `StubAgents` with the stubs this needs, and add a pid file to each
stub it reuses:

- one that exits in the middle of a turn;
- one that writes an invalid JSON-RPC answer;
- one that ends its turn with `refusal` — the earlier tasks scripted a refusal
  in the **unit** suite only, over an in-memory pair, so no shell-script stub
  for it exists yet.

## Acceptance Criteria

- [ ] Each of the six exit paths leaves no agent process.
- [ ] A grandchild of the agent is gone too.
- [ ] An agent that dies in the middle of a turn gives exit 1 and is reaped,
      not left as a zombie.
- [ ] The suite fails loudly, naming the pid and the exit path, when a process
      is still alive.

## Tests

- [ ] `NoLeakedAgentTests.swift`, one test per acceptance row above.
- [ ] One test asserts the zombie case directly: after the binary exits,
      `waitpid` for the agent pid reports no such process, so the pid was
      reaped and not merely killed.
- [ ] One test runs the whole set twice in a row and asserts the second run is
      unaffected by the first, which catches a leaked descriptor.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.