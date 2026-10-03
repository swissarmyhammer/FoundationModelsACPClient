---
assignees:
- claude-code
position_column: todo
position_ordinal: '9480'
title: 'AgentProcess.spawn: close the pipe()/fcntl window with POSIX_SPAWN_CLOEXEC_DEFAULT'
---
## What
`AgentProcess.createPipe()` in `Sources/FoundationModelsACPClient/AgentProcess.swift` calls `pipe(2)` and then sets `FD_CLOEXEC` with `fcntl`. Its doc says: "The flag goes on both ends here, directly after `pipe(2)` and before any spawn on any thread, so no child can inherit either end." That is not true. Another thread can call `posix_spawn` between the `pipe` call and the `fcntl` call. That child then holds a copy of the write end of the agent's stdin. The agent reads no end of file after `closeStandardInput()` until that other child exits.

Found during ^h5z930j: the test helper `spawnInThisProcessGroup` had the same window, and it now uses `POSIX_SPAWN_CLOEXEC_DEFAULT`.

- [ ] Add `POSIX_SPAWN_CLOEXEC_DEFAULT` to the spawn attributes in `AgentProcess.spawnChild`, beside `POSIX_SPAWN_SETPGROUP`. Then the child holds only the descriptors the file actions name (0 and 1), whatever a parallel thread does. Check that stderr of the agent still reaches the host: add `posix_spawn_file_actions_addinherit_np` for `STDERR_FILENO` if the agent must keep it.
- [ ] Correct the doc of `createPipe()`: the flag alone does not close the race.
- [ ] Write a failing test first (`/tdd`).

## Acceptance Criteria
- [ ] A child of `AgentProcess.spawn` holds no descriptor of this process except its stdin, stdout and (if kept) stderr.
- [ ] `swift test` passes.