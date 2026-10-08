---
comments:
- actor: claude-code
  id: 01m4dvc8wkqxasz9pa8h6hcf7k
  text: |-
    Research done.
    - `AgentProcess` spawns with raw `posix_spawn` in `AgentProcess.spawnChild(command:arguments:descriptors:processGroup:)`. It gives `environ` as envp, and it does not set a directory. `posix_spawn_file_actions_addchdir_np` sets the directory of the child before the exec (macOS 26 floor is 27, so it is available).
    - The exit status is lost now: `AgentProcessState.reap(pid:)` calls `waitpid` but discards `status`. Every teardown path (EOF of stdout, `shutdown()`, stream end, deinit) goes through `terminateCurrent()`, so that is the one place to record the status.
    - When the agent exits by itself, the reader thread gets EOF and runs `terminateCurrent()`. `killpg` on the zombie group has no effect, and `waitpid` then gives the real exit status. When the host calls `shutdown()` first, the status is the `SIGKILL` signal.
    - The reap can give up after the reap time limit. Then no status exists, so the status type needs a case for "not collected", or an awaiting host waits forever.
    - The test helper `outcome(within:of:)` cancels the work at its limit, so an await of the exit must obey task cancellation.
    - Plan: add `environment: [String: String]?` and `currentDirectory: String?` (nil = inherit) to the public and the registry init, and to `spawnChild` with defaults. Add `AgentExitStatus` (exited code, signaled signal, notCollected), a small latch in `AgentProcessState`, `AgentProcess.exitStatus` (sync, nil while live) and `AgentProcess.waitForExit()` (async, throws `CancellationError`).
  timestamp: 2026-10-08T13:31:23.923178+00:00
- actor: claude-code
  id: 01m4dvz853txdz6xcw5wy0167m
  text: |-
    Implementation landed (TDD: the new suite failed first, on the missing API).
    - `AgentProcess.init(command:arguments:environment:currentDirectory:)`: `environment` replaces the environment of the host (it does not add to it); `nil` keeps the old behavior. `currentDirectory` is a `posix_spawn_file_actions_addchdir` file action, so only the child changes directory. A directory the child cannot enter throws `spawnFailed(command:errno: ENOENT)`.
    - New file `AgentExitStatus.swift`: `AgentExitStatus` (`exited(code:)`, `signaled(signal:)`, `notCollected`) and `AgentExitLatch`. `terminateCurrent()` records the status after the reap and the deregister. `AgentProcess.exitStatus` (nil while live) and `AgentProcess.waitForExit()` (async, throws `CancellationError` on cancel) read it.
    - Discovery: `posix_spawn_file_actions_addchdir_np` is deprecated in macOS 26 and gives a compiler warning. The code uses `posix_spawn_file_actions_addchdir`.
    - Discovery: a shutdown of a live child records `signaled(signal: SIGKILL)`; a child that exits by itself records its real code, because EOF comes first and `killpg` on a zombie group has no effect.
    - Test helper: `StdioChild.wholeStandardOutput(of:)` is now shared; `descriptorProbeAnswer` in the pipe inheritance tests uses it.
    - The only warning left in the build is the known MLX "missing creator for mutated node" SwiftPM warning, which the user accepted in ^…3Z8M7 (not caused by this change).
    - No ARCHITECTURE.md exists.
  timestamp: 2026-10-08T13:41:45.763261+00:00
- actor: claude-code
  id: 01m4dvzc27v6jnpx67vyv9egvn
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACPClient/AgentProcess.swift, Sources/FoundationModelsACPClient/AgentExitStatus.swift (new), Tests/FoundationModelsACPClientTests/AgentProcessLaunchTests.swift (new), Tests/FoundationModelsACPClientTests/StdioChild.swift, Tests/FoundationModelsACPClientTests/AgentProcessPipeInheritanceTests.swift, Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift (doc link). `swift test`: 586 tests in 50 suites passed; `swift build --package-path IntegrationTests --build-tests`: build complete.
    - next: /review
  timestamp: 2026-10-08T13:41:49.767259+00:00
- actor: claude-code
  id: 01m4dvzfrd2xch8xr6n3e01mc1
  text: 'Correction to the step record above: the change touches 6 files, not 7. The list of files in that record is correct.'
  timestamp: 2026-10-08T13:41:53.549777+00:00
- actor: claude-code
  id: 01m4dw22hwa8jv7c1jg1py4jv9
  text: |-
    ### test — green
    - evidence: swift test — 586 tests in 50 suites passed, 0 failed, 0 skipped. swift build --package-path IntegrationTests --build-tests — Build complete. No compiler warning in the code of this package.
    - note: SwiftPM prints one build-system line, "missing creator for mutated node" for the mlx-swift_Cmlx.bundle of a dependency. It is not a compiler warning and no source file of this package causes it.
    - next: review
  timestamp: 2026-10-08T13:43:18.332168+00:00
- actor: claude-code
  id: 01m4dw6r7dmqh2g58x1k1xjw4b
  text: |-
    ### test — red (correction of the comment above)
    - evidence: swift test — 586 tests in 50 suites passed, 0 failed, 0 skipped. swift build --package-path IntegrationTests --build-tests — Build complete. After swift package clean, swift build --build-tests — Build complete.
    - open warnings: all come from the dependency mlx-swift, not from a file of this package. (1) "missing creator for mutated node" for mlx-swift_Cmlx.bundle, in swift test, in swift build and in the IntegrationTests build. (2) C++17 extension warnings from the mlx-swift checkout in a clean build. Task ^zws9qzt is in done, but the warning is still present.
    - the rule is zero warnings, so the outcome word is red. No file of ^xz6sdn0 causes a warning or a failure.
    - next: a person decides if ^zws9qzt is reopened, or if the caller accepts the dependency warnings.
  timestamp: 2026-10-08T13:45:51.597572+00:00
position_column: doing
position_ordinal: '80'
title: 'AgentProcess: environment and working directory parameters, and the exit status'
---
## What
Request from AgentViewKit (task ^ma57bws there). `AgentProcess` has only `init(command:arguments:)`. The child process gets the environment of the host, and the host cannot set the working directory. Thus the AgentViewKit `AgentProcessLauncher` starts the agent through `/usr/bin/env`. The exit status of the agent process is not available to the host.

- [x] Add an `environment` parameter to `AgentProcess`. The child gets this environment.
- [x] Add a `currentDirectory` parameter to `AgentProcess`. The child starts in this directory.
- [x] Give the exit status of the process when it ends, as a value that the host can await or as observable state.

## Acceptance Criteria
- [x] A host can set the environment and the working directory of the child with no `/usr/bin/env` wrapper.
- [x] A host can read the exit status after the child ends.

## Tests
- [x] A test starts a small child program and checks that it gets the given environment and working directory.
- [x] A test checks that the host gets the exit status of a child that exits with a status that is not zero.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.