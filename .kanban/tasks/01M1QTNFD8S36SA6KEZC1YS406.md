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
- actor: claude-code
  id: 01m1rn5nqdn1qd7b0qpjzyyaac
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit 249dd32) — 3 findings, 3 confirmed, 0 refuted: Sources/FoundationModelsACPClient/AgentProcess.swift:595, Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift:64, Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift:113
    - next: implement step corrects the three `swift/fluent-usage` items in the `## Review Findings (2026-09-05 06:22)` section, then runs the tests and a new review
  timestamp: 2026-09-05T11:27:29.517987+00:00
- actor: claude-code
  id: 01m1rn6etybffgpmgcrpg5594e
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 2 files: `Sources/FoundationModelsACPClient/AgentProcess.swift`, `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift` (new). Counterfactual: both new tests hung 75 s and more on the unfixed teardown, then passed 5/5 after the fix.
    - test: green — root 223/223 in 19 suites, integration 77/77 in 12 suites, 0 warnings, 0 skipped
    - commit: 249dd32
    - review: findings — `Sources/FoundationModelsACPClient/AgentProcess.swift:595`, `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift:64`, `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift:113` (all `swift/fluent-usage`: label the first parameter)
  timestamp: 2026-09-05T11:27:55.230410+00:00
- actor: claude-code
  id: 01m1rn8cw56j8x8xh3gn5zf700
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (a57cdd1). 0 findings, 0 confirmed, 0 refuted, 7 validator runs, 0 failed. 2 files reviewed. 4 files in .kanban/ not reviewed (excluded by .reviewignore). No prior findings section. All 3 checklist items are checked.
    - next: done
  timestamp: 2026-09-05T11:28:58.757804+00:00
- actor: claude-code
  id: 01m1rn9wwhxh83dj2hcfd8p1j1
  text: |-
    ### review — findings
    - correction: the step record above this one ("review — clean") is withdrawn. The card read at the start of this pass did not show the `## Review Findings (2026-09-05 06:22)` section. The section was written between that read and the move. The three items in it are not checked, so the task must stay in `review`. The task is moved back from `done` to `review`.
    - evidence: review sha HEAD~1..HEAD. 0 new findings, 0 confirmed, 0 refuted, 7 validator runs, 0 failed. 2 files reviewed. 4 files in .kanban/ not reviewed (excluded by .reviewignore). The clean section `## Review Findings (2026-09-05 06:27)` is appended to the description. 3 prior findings stay open: Sources/FoundationModelsACPClient/AgentProcess.swift:595, Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift:64, Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift:113.
    - next: implement. Correct the three `swift/fluent-usage` items in the `## Review Findings (2026-09-05 06:22)` section, mark them, run the tests, then run a new review.
  timestamp: 2026-09-05T11:29:47.921581+00:00
- actor: claude-code
  id: 01m1rnafrvtfxeyrfyq1tphqm1
  text: |-
    ### Research (findings pass)

    - The rule `swift/fluent-usage` says: "Omit the first argument label only for value-preserving conversions. Otherwise, label it."
    - Commit 249dd32 added one function to `AgentProcess.swift`: `reap(_ pid:)`. Its one caller is `terminateCurrent()`.
    - The test file has four functions with an unlabeled first parameter. Three are in the findings: `spawnInThisProcessGroup(_ command:arguments:)`, `killAndReap(_ pid:)`. The fourth, `isInProcessTable(_ pid:)`, is a predicate and not a conversion, so it has the same cause. It gets the same correction.
    - All four functions are `private`. Each caller is in the same file, so no file outside the two named files changes.
    - `AgentProcess.swift` has four other functions with an unlabeled first parameter: `freePointers(_:)`, `write(_:)`, `writeToStdin(_:)` and `fullyWrite(_:_:)`. Commit 249dd32 did not add them, so they are out of the scope of this card. `write(_:)` is also the `ACPTransport` protocol signature, so a label there would not compile.

    ### Changes

    - `Sources/FoundationModelsACPClient/AgentProcess.swift`: `reap(_ pid:)` is now `reap(pid:)`, and `terminateCurrent()` calls `reap(pid: taken.pid)`.
    - `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift`: `spawnInThisProcessGroup(command:arguments:)`, `isInProcessTable(pid:)` and `killAndReap(pid:)`, with all six call sites labeled.

    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPClient/AgentProcess.swift (1 signature, 1 call site), Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift (3 signatures, 6 call sites). `swift test` (root): 223 tests in 19 suites passed, 0 failed, 0 skipped, 0 warnings. `swift test --package-path IntegrationTests`: 77 tests in 12 suites passed, 0 failed, 0 skipped, 0 warnings. The three items in `## Review Findings (2026-09-05 06:22)` are checked. No probe changes are in the tree.
    - next: review
  timestamp: 2026-09-05T11:30:07.259617+00:00
- actor: claude-code
  id: 01m1rncnvjqfb7by0t8sjyaf83
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 2 files: `Sources/FoundationModelsACPClient/AgentProcess.swift`, `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift` (new). Counterfactual: both new tests hung 75 s and more on the unfixed teardown, then passed 5/5 after the fix.
    - test: green — root 223/223 in 19 suites, integration 77/77 in 12 suites, 0 warnings, 0 skipped, diagnostics 0 warnings
    - commit: a57cdd1 (249dd32 amended with the kanban state written after it; same tree, same message)
    - review: findings — 0 new findings on a57cdd1; 3 prior findings open at review time: `Sources/FoundationModelsACPClient/AgentProcess.swift:595`, `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift:64`, `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift:113` (all `swift/fluent-usage`: label the first parameter)
    - note: the `finish iteration 1` entry above was written by a parallel actor for the same change (249dd32). A parallel implement pass then labeled the parameters and checked the three findings; its edits are in the tree and not committed. The next iteration tests, commits and reviews that tree.
  timestamp: 2026-09-05T11:31:19.026788+00:00
- actor: claude-code
  id: 01m1rnd875qwmntsbs5kqjk52e
  text: |-
    ### implement — no-change
    - evidence: the three checked items in `## Review Findings (2026-09-05 06:22)` are compared with `git diff`: `reap(pid:)` at AgentProcess.swift:595 and its call at line 575; `spawnInThisProcessGroup(command:arguments:)` at AgentProcessTeardownTests.swift:63; `killAndReap(pid:)` at line 113; `isInProcessTable(pid:)` at line 104 has the same correction; all six call sites are labeled. The edits are in the tree and not committed. This pass modified no file.
    - next: test, commit, review
  timestamp: 2026-09-05T11:31:37.829360+00:00
- actor: claude-code
  id: 01m1rndj793v4akktxb7kkm7x0
  text: |-
    ### test — green
    - command: `swift test` (root). result: 223 tests in 19 suites passed. 0 failed. 0 warnings. 0 skipped.
    - command: `swift test --package-path IntegrationTests`. result: 77 tests in 12 suites passed. 0 failed. 0 warnings. 0 skipped.
    - No leftover agent process after the run. No probe change is in the tree.
    - next: review
  timestamp: 2026-09-05T11:31:48.073473+00:00
- actor: claude-code
  id: 01m1rnfjrpz7053v22raw88qg8
  text: |-
    ### commit — changed
    - evidence: bc52417 style(process): label the first parameter of action functions
  timestamp: 2026-09-05T11:32:54.166574+00:00
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

## Review Findings (2026-09-05 06:22)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPClient/AgentProcess.swift:595` `swift/fluent-usage` — First parameter of function should be labeled. The rule states to omit the first argument label only for value-preserving conversions; this function performs an action (reaping a process), not a conversion. Change `_ pid:` to `pid:` so calls read as `reap(pid: taken.pid)` instead of `reap(taken.pid)`.
- [x] `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift:64` `swift/fluent-usage` — First parameter of function should be labeled. This is not a value-preserving conversion; it spawns a process. Change `_ command:` to `command:` so calls read as `spawnInThisProcessGroup(command: readingChildCommand, arguments: [])` instead of `spawnInThisProcessGroup(readingChildCommand, arguments: [])`.
- [x] `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift:113` `swift/fluent-usage` — First parameter of function should be labeled. This function performs an action (killing and reaping), not a value-preserving conversion. Change `_ pid:` to `pid:` so calls read as `killAndReap(pid: child.pid)` instead of `killAndReap(child.pid)`.
