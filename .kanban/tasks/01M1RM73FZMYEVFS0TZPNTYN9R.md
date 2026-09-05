---
assignees:
- claude-code
position_column: todo
position_ordinal: 9f80
title: AgentProcess.spawn lets a second agent inherit the first agent's pipe ends
---
## What

`AgentProcess.spawn` creates the two stdio pipes and then calls `posix_spawn`. A child that `posix_spawn` starts inherits every open descriptor of the host, unless the descriptor carries `FD_CLOEXEC`. The spawn closes the four pipe ends inside the NEW child with `posix_spawn_file_actions_addclose`, but a DIFFERENT child that another `AgentProcess` spawns at the same moment gets copies of this agent's pipe ends and keeps them.

Found while the teardown tests of ^c1ys406 ran in parallel: the `sleep` child of one test held a copy of the write end of the `cat` pipe of the other test, and the `cat` child did not get its EOF when the teardown closed the host's own copy.

## Why it matters

Two agents spawned in one host at the same time can each hold the other's stdin write end. Then `closeStandardInput()` and the teardown's stdin close do not reach the other agent as EOF until the first agent exits. The doctor's check 7 and the teardown of ^c1ys406 both depend on that EOF.

## What to do

- [ ] Set `FD_CLOEXEC` on all four pipe ends in `AgentProcess.spawn` directly after `pipe(2)`, before `posix_spawn`. The `dup2` file actions still put the child's ends on descriptors 0 and 1, because `dup2` clears the flag on the new descriptor.
- [ ] A unit test spawns two children at the same time and proves that a stdin close of the first one reaches it as EOF while the second one is alive.

## Files

- `Sources/FoundationModelsACPClient/AgentProcess.swift`, `AgentProcess.spawn(command:arguments:)` and `AgentProcess.createPipe()`
- `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift` has the `FD_CLOEXEC` shape for the test helper.