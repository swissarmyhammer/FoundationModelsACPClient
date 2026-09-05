---
assignees:
- claude-code
position_column: todo
position_ordinal: 9d80
title: AgentProcess teardown blocks forever when the group kill misses
---
## What

`AgentProcessState.terminateCurrent()` runs three steps in this order:

1. `killpg(taken.pid, SIGKILL)`
2. `waitpid(taken.pid, &status, 0)` — a BLOCKING wait
3. `close(taken.stdinWriteDescriptor)`

Step 2 blocks until the agent exits, and step 3 is the one thing that would
make a live agent exit on its own. So whenever step 1 fails to reach the
agent, the teardown never returns and the whole host hangs.

Measured while sweeping §11 (task ^f1fz3bv). One character was changed —
`killpg` to `kill` — and `acp-client` stopped exiting at all against a stub
agent that leaves a child holding the pipes; the integration suite ran past
240 seconds where it takes 10 seconds unmutated.

`killpg` reaching the agent is not a fact the code can rely on: it fails with
`ESRCH` for a pid that is no longer a group leader, which is what happens when
the spawn attributes stop asking for `POSIX_SPAWN_SETPGROUP`, and it fails with
`EPERM` for a group this process may not signal.

## Why it matters

The whole of `cli-plan.md` §11 rests on this one function. A defect that turns
a leak into a HANG is worse than the leak: the run never ends, so nothing
reports the failure, and every §11 test then fails as a time limit rather than
as the named claim it makes.

## What to do

- [ ] Close the agent's stdin BEFORE the blocking wait, so an agent the signal
      missed still reaches its own end of file.
- [ ] Bound the wait, or take `WNOHANG` and poll to a deadline, so a teardown
      always returns.
- [ ] A unit test drives a teardown whose signal reaches nothing, and asserts
      the call returns.

## Files

- `Sources/FoundationModelsACPClient/AgentProcess.swift`,
  `AgentProcessState.terminateCurrent()`
