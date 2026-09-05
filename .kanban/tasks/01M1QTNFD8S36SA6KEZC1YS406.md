---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rkqpmy0mgmgvsxzc7w6368
  text: |-
    ### Research

    - `AgentProcessState.terminateCurrent()` (Sources/FoundationModelsACPClient/AgentProcess.swift) does: take-and-clear under the lock, `killpg(pid, SIGKILL)`, `waitpid(pid, &status, 0)`, then `close(stdin)`, then `registry.deregister(pid)`. The wait has no time limit, and the stdin close comes after the wait. This is the defect the card describes.
    - The callers of `terminateCurrent()` are: `AgentProcess.shutdown()`, the stream `continuation.onTermination` closure in `AgentProcess.init`, the two exits of `AgentProcess.readLoop` (EOF and read error), and `AgentProcessState.deinit`. `shutdown()` is called from `RunCommand`, `ProbeCommand`, `AgentCommandDoctor` and the integration tests. None of the callers reads a result, so a change inside the function does not change a signature.
    - `AgentProcessState` is `internal`, so a unit test in the root test target reaches it with `@testable import`.
    - The root test target has no test that spawns a process. The family precedent for a spawned child in a unit test is `ProcessRegistryTests` in FoundationModelsExtras: it spawns `/bin/sleep` with `posix_spawn` and uses a private `ProcessRegistry()` so a sweep cannot reach a pid the test does not own.
    - A child that `posix_spawn` starts WITHOUT `POSIX_SPAWN_SETPGROUP` stays in the test runner's process group. Then `killpg(childPid, ...)` fails with `ESRCH`, because no process group has that id. This is the exact condition the card names, and it needs no mutation of the source.

    ### Plan

    1. New unit test file `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift`. A helper spawns `/bin/cat` or `/bin/sleep` in this process group with its stdin on a pipe, and records the pid in an `AgentProcessState` over a private registry.
       - Test 1: the child is `/bin/cat`. The teardown must return, and the child must be reaped. Only a stdin close BEFORE the wait can make `cat` exit.
       - Test 2: the child is `/bin/sleep`. It ignores EOF. The teardown must return by the reap deadline, and the test then kills the child itself.
    2. `AgentProcessState.init(registry:reapTimeLimit:)` gets a `Duration` parameter with a named default, so the test can use a short limit.
    3. `terminateCurrent()` closes stdin before the wait, and the wait becomes `waitpid(..., WNOHANG)` polled at a named interval until a named deadline.
    4. Counterfactual: run the new tests against the source BEFORE step 3, and record the hang.
  timestamp: 2026-09-05T11:02:23.134768+00:00
- actor: claude-code
  id: 01m1rm22b92zm4zbsc9q66v3v2
  text: |-
    ### Counterfactual evidence (RED, unfixed teardown)

    Source state: `AgentProcessState` had only the new `init(registry:reapTimeLimit:)` seam (a stored `Duration`, not yet read). `terminateCurrent()` was the original: `killpg`, then a blocking `waitpid(pid, &status, 0)`, then the stdin close.

    Test file: `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift`, two tests. Each spawns a child with `posix_spawn` and no `POSIX_SPAWN_SETPGROUP`, so `killpg(childPid, SIGKILL)` fails with `ESRCH` (the first test asserts that with `killpg(pid, 0)`).

    Run 1: `swift test --skip-build --filter AgentProcessTeardownTests` in the background, output to a file. After 80 s the log was empty (the runner buffers without a terminal). The process table 2 minutes after the start:

    ```
    70301  ppid 1  S  02:01  swiftpm-testing-helper --test-bundle-path .../FoundationModelsACPClientTests ... --filter AgentProcessTeardownTests
    70303  ppid 70301  S  02:01  /bin/sleep 300
    ```

    The test host stayed alive with the test's child under it. The `defer { killAndReap(child.pid) }` of the test never ran, so the test function never returned.

    Run 2: the same command under `script` (a pseudo-terminal), 75 s:

    ```
    Test run started.
    Suite "AgentProcessState teardown when the group kill misses" started.
    Test teardownReturnsByTheDeadlineWhenTheAgentOutlivesTheGroupKill() started.
    Test teardownReapsAnAgentTheGroupKillMissedOnceItsStdinCloses() started.
    ```

    No test ended. The process table after 75 s:

    ```
    73412  swiftpm-testing-helper ...   01:13
    73413  /bin/sleep 300               01:13   (child of 73412)
    73414  /bin/cat                     01:13   (child of 73412)
    ```

    Both tests hung in the blocking `waitpid`. The `cat` child hung too, because its stdin was still open: the close came after the wait. The suite `.timeLimit(.minutes(1))` did not end the run, because a blocked `waitpid` cannot observe a task cancellation. I killed the leftover processes by pid.

    Result: RED. Both tests bite on the unfixed code.
  timestamp: 2026-09-05T11:08:02.793374+00:00
- actor: claude-code
  id: 01m1rm6jmgvnpd0z57v0kp75j3
  text: |-
    ### GREEN, and the second probe

    Fix applied in `AgentProcessState.terminateCurrent()`: `killpg`, then the stdin close, then `reap(pid)`, then the registry deregister. `reap` polls `waitpid(pid, &status, WNOHANG)` every `reapPollInterval` (10 ms) until the child is collected or the `reapTimeLimit` deadline ends. `init(registry:reapTimeLimit:)` takes the limit, with `defaultReapTimeLimit` (5 s) as the default; `AgentProcess.init` uses the default.

    `swift test --filter AgentProcessTeardownTests`, five runs in a row, each: 2 tests passed, 0 issues, no leftover process.

    - `teardownReapsAnAgentTheGroupKillMissedOnceItsStdinCloses` passed in 0.011 to 0.013 s: `cat` exits on the EOF and the first poll collects it.
    - `teardownReturnsByTheDeadlineWhenTheAgentOutlivesTheGroupKill` passed in 0.205 to 0.210 s: `sleep` ignores the EOF, and the teardown returns at the 200 ms limit.

    Second probe, for the first checkbox alone: I moved the stdin close AFTER `reap(pid)` (the bounded wait stayed), rebuilt, and ran test 1. It failed at the 0.201 s deadline with `Expectation failed: !isInProcessTable(child.pid)`. So the test tells the order of the close and the wait apart, and not only the presence of a time limit. The probe is reverted; the tree holds the real fix only.

    ### What did not work

    The first GREEN run failed test 1, with `cat` still alive after the teardown. Cause: the tests of one target run in parallel, and `posix_spawn` lets a child inherit every open descriptor of the parent, so the `sleep` child of test 2 held a copy of the write end of the `cat` pipe. The test helper now sets `FD_CLOEXEC` on both pipe ends before the spawn.

    That same inheritance is a latent hazard in `AgentProcess.spawn`: two agents spawned at the same time in one host can each inherit the other's pipe ends, and a stdin close then does not reach the other agent as EOF. It is out of the scope of this card; I filed it as a new task.
  timestamp: 2026-09-05T11:10:30.544915+00:00
- actor: claude-code
  id: 01m1rmp7dx5s3ax1zyhhwa6wma
  text: |-
    ### Disk note

    The first attempt to write this step record failed with "No space left on device": the Data volume was at 100 % with 105 MiB free, and `IntegrationTests/.build` held 43 GB of build artifacts. `swift package clean` could not run on the full disk (even `swiftc -print-target-info` failed), so I removed the artifact directories under `IntegrationTests/.build` directly and kept `checkouts`, `repositories` and `workspace-state.json`. 36 GiB is free now. The root `.build` is untouched.

    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPClient/AgentProcess.swift (stdin close before the reap, `reap(_:)` with `WNOHANG` polls at `reapPollInterval` until `reapTimeLimit`, `init(registry:reapTimeLimit:)` with `defaultReapTimeLimit`, doc updates), Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift (new; 2 tests). RED: both tests hung 75 s and more on the unfixed teardown, host and children alive. GREEN: `swift test` 223 tests in 19 suites passed; `swift test --package-path IntegrationTests` 77 tests in 12 suites passed; `swift build` and LSP diagnostics with 0 warnings. Second probe: the close after the wait fails test 1 at the 0.201 s deadline; reverted. New task ^pntyn9r filed for the descriptor inheritance in `AgentProcess.spawn`.
    - next: review
  timestamp: 2026-09-05T11:19:03.357911+00:00
- actor: claude-code
  id: 01m1rmsym8dzt0v5m6z30ab0ez
  text: |-
    ### test — green
    - Command: `swift test` (root package). Result: 223 tests in 19 suites passed. 0 failed. 0 warnings. 0 skipped.
    - Command: `swift test --package-path IntegrationTests`. Result: 77 tests in 12 suites passed. 0 failed. 0 warnings. 0 skipped.
    - The new test `teardownReturnsByTheDeadlineWhenTheAgentOutlivesTheGroupKill()` ran and passed.
    - No probe changes were made. No files were left changed by this test step.
    - Next step: review.
  timestamp: 2026-09-05T11:21:05.416802+00:00
- actor: claude-code
  id: 01m1rmvtacc6neqzxcyj9k51g9
  text: |-
    ### commit — changed
    - evidence: 249dd32 fix(process): bound the teardown wait to a deadline
  timestamp: 2026-09-05T11:22:06.540220+00:00
position_column: review
position_ordinal: '80'
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

- [x] Close the agent's stdin BEFORE the blocking wait, so an agent the signal
      missed still reaches its own end of file.
- [x] Bound the wait, or take `WNOHANG` and poll to a deadline, so a teardown
      always returns.
- [x] A unit test drives a teardown whose signal reaches nothing, and asserts
      the call returns.

## Files

- `Sources/FoundationModelsACPClient/AgentProcess.swift`,
  `AgentProcessState.terminateCurrent()`
