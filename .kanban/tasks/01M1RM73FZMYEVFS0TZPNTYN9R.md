---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rwxrjrvabgezkdtfbcre7n
  text: |-
    Research done.

    - `AgentProcess.spawn` makes two pipes with `createPipe()`. The spawn closes only the four ends of its OWN spawn, inside its OWN child, with `posix_spawn_file_actions_addclose`. The host keeps its write end of stdin and its read end of stdout open for the life of the agent.
    - A second `AgentProcess`, spawned AFTER the first, inherits copies of the two host-side ends of the first agent. The defect is deterministic. It does not need a race between two threads: a sequential spawn of `cat` and then `sleep 300` shows it. The race between two threads is the same defect with a smaller window.
    - The fix goes into `createPipe()`: `fcntl(F_SETFD, FD_CLOEXEC)` on both ends directly after `pipe(2)`. Then no `posix_spawn` from any thread can pass either end on. The `dup2` file actions still put the child's ends on 0 and 1, because `dup2` clears the flag on the new descriptor.
    - Test plan, red first: a unit test spawns `/bin/cat` through `AgentProcess`, then `/bin/sleep 300`, closes the stdin of `cat`, and waits for the byte stream of `cat` to end within `TransportTestDeadline.limit`. With the defect, the `sleep` child holds a copy of the write end, `cat` never reads its end of file, and the wait ends at the limit.
    - The bounded wait is a new shared helper `outcome(within:of:)` in `TransportTestSupport.swift`. `waitForIdle` goes through it, so the task-group shape has one copy.
    - The child commands and the process-table test move to a shared `StdioChild` namespace, so the new test and the teardown tests do not hold two copies.
  timestamp: 2026-09-05T13:42:58.904526+00:00
- actor: claude-code
  id: 01m1rx4t3ndbq9wz9f5t07z75a
  text: |-
    Red, then green, then one interaction with an existing test.

    - RED: `swift test --filter AgentProcessPipeInheritanceTests` failed after 10.553 s: `Expectation failed: endedAtEndOfFile`. The byte stream of `cat` did not end within `TransportTestDeadline.limit` (10 s), because the `sleep` child held a copy of the write end of the stdin of `cat`. The other two expectations passed. The bounded wait tore the `cat` agent down through task cancellation, and `pgrep` found no `cat` and no `sleep 300` after the run.
    - GREEN: `createPipe()` sets `FD_CLOEXEC` on both ends directly after `pipe(2)`. The same filtered run passed in 0.032 s.
    - REFACTOR: the child commands and the process-table check moved to `StdioChild`, and the teardown tests use them.
    - The full root run then failed ONE test: `AgentSessionSpawnTests.drivingTheSeamRegistersNoProcess()`. It snapshots `ProcessRegistry.global.registeredPids` and asserts the seam adds no pid. Its `.serialized` trait covers its own suite only, and my test ran beside it and registered two pids in the global registry. Fix: `AgentProcess` got an internal `init(command:arguments:registry:)`; the public `init(command:arguments:)` delegates to it with `.global`. The new test spawns into a private `ProcessRegistry()`, and it now also asserts that the registry holds only the idle pid after the reader reached end of file.
  timestamp: 2026-09-05T13:46:49.845323+00:00
- actor: claude-code
  id: 01m1rx73t59wencz2gpv0210kj
  text: |-
    ### implement — changed
    - evidence: 5 files. `Sources/FoundationModelsACPClient/AgentProcess.swift`: `createPipe()` sets `FD_CLOEXEC` on both ends directly after `pipe(2)`, and closes both ends and throws `pipeCreationFailed` when the flag cannot be set; an internal `init(command:arguments:registry:)` holds the spawn, and the public `init(command:arguments:)` delegates to it with `.global`; the doc of `pipeCreationFailed` and the comment on the close file actions state the flag. `Tests/FoundationModelsACPClientTests/AgentProcessPipeInheritanceTests.swift` (new): spawns `cat` and then `sleep 300` through `AgentProcess` into a private `ProcessRegistry`, closes the stdin of `cat`, waits for the byte stream of `cat` to end within `TransportTestDeadline.limit`, and asserts that the reader is reaped and deregistered while the idle agent lives. `Tests/FoundationModelsACPClientTests/StdioChild.swift` (new): the shared child commands and the process-table check. `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift`: uses `StdioChild`. `Tests/FoundationModelsACPClientTests/TransportTestSupport.swift`: new `outcome(within:of:)`, and `waitForIdle` goes through it. RED: `swift test --filter AgentProcessPipeInheritanceTests` failed after 10.553 s with `Expectation failed: endedAtEndOfFile`, because the `sleep` child held a copy of the write end of the stdin of `cat`. GREEN: the same run passed in 0.032 s after the `FD_CLOEXEC` change. `swift test`: 224 tests in 20 suites passed, 0 failures, 0 warnings, 0 skipped. `swift test --package-path IntegrationTests`: 87 tests in 12 suites passed, 0 failures, 0 warnings, 0 skipped. `pgrep` finds no `cat` and no `sleep 300` after the runs.
    - next: /review
  timestamp: 2026-09-05T13:48:05.317563+00:00
- actor: claude-code
  id: 01m1rxb4nqr4sgkw14gptxrrjp
  text: |-
    ### test — green
    - evidence: `swift test`: 224 tests in 20 suites passed, 0 failures, 0 warnings, 0 skipped. `swift test --package-path IntegrationTests`: 87 tests in 12 suites passed, 0 failures, 0 warnings, 0 skipped. `swift package clean && swift build --build-tests` gave a clean build with no warning lines. `pgrep -fl 'sleep 300'` and `pgrep -fl cat` found no live child process after both runs.
    - next: /review
  timestamp: 2026-09-05T13:50:17.271718+00:00
- actor: claude-code
  id: 01m1rxcrnqbw7egyrn94qykfr7
  text: |-
    ### commit — changed
    - evidence: caf0531 fix(process): set FD_CLOEXEC on pipe ends to stop cross-agent fd leaks
    - next: proceed to review
  timestamp: 2026-09-05T13:51:10.519678+00:00
- actor: claude-code
  id: 01m1rxkew23efdtawzdjwmqkd5
  text: |-
    ### review — findings
    - evidence: 1 finding — Sources/FoundationModelsACPClient/AgentProcess.swift:329 (swift/naming-clarity). Scope: review sha HEAD~1..HEAD (commit caf0531).
    - next: Rename the loop variable `open` in the cleanup path of `AgentProcess.spawn` to `descriptor`. Then run the review again.
  timestamp: 2026-09-05T13:54:49.858782+00:00
- actor: claude-code
  id: 01m1rxkzqq2xz0be1pvej7t073
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files: `Sources/FoundationModelsACPClient/AgentProcess.swift` (`FD_CLOEXEC` in `createPipe()`, internal `init(command:arguments:registry:)`), `Tests/.../AgentProcessPipeInheritanceTests.swift` (new), `Tests/.../StdioChild.swift` (new), `Tests/.../AgentProcessTeardownTests.swift`, `Tests/.../TransportTestSupport.swift`. Red: the new test failed after 10.5 s with `endedAtEndOfFile` false; green in 0.03 s after the flag.
    - test: green — root 224/224 in 20 suites, integration 87/87 in 12 suites, 0 warnings, 0 skipped; no child process outlived the runs
    - commit: caf0531
    - review: findings — `Sources/FoundationModelsACPClient/AgentProcess.swift:329` (`swift/naming-clarity`: loop variable `open` shadows the global `open()`; rename to `descriptor`)
  timestamp: 2026-09-05T13:55:07.127165+00:00
- actor: claude-code
  id: 01m1rxrjh61198jstn83cmhrna
  text: |-
    Implement, second pass, for the one review finding.

    - The finding: `Sources/FoundationModelsACPClient/AgentProcess.swift:329` `swift/naming-clarity` — Loop variable `open` does not clarify its role and shadows the global `open()` function. In this cleanup path, the variable represents a file descriptor to close, not a state or property. The name should reflect its actual role. Rename to `fd` or `descriptor` to clarify the loop variable represents a file descriptor, not a descriptor state. For consistency with the outer loop, `descriptor` is preferred: `for descriptor in descriptors { close(descriptor) }`.
    - The change: the cleanup loop in `createPipe()` is now `for descriptor in descriptors { close(descriptor) }`, the shape the finding gives. `fd` was not an option, because the `swift/naming-clarity` rule forbids an abbreviation.
    - The whole file was read for the same cause. No other local name in `AgentProcess.swift` shadows a global C function. The local names are `descriptor`, `descriptors`, `failure`, `pid`, `status`, `count`, `buffer`, `offset`, `written`, `raw`, `base`, `taken`, `recorded`, `current`, `clock`, `deadline`, `argv`, `attributes`, `fileActions`, `spawnResult`, `pointer`, `spawned`, `stream`, `continuation`, `state`, `thread`, and the four pipe ends. None of them is a C function. The public API is unchanged.
    - No new test: a rename of a local variable changes no behavior, and no test can observe a local name. The existing test `AgentProcessPipeInheritanceTests` covers `createPipe()` and stays green.
    - `swift test` (root): 224 tests in 20 suites passed, 0 failures, 0 skipped. The build recompiled `FoundationModelsACPClient` and printed no warning line. `swift test --package-path IntegrationTests`: 87 tests in 12 suites passed, 0 failures, 0 skipped, no warning line. `pgrep` finds no `cat` and no `sleep 300` after the runs.
  timestamp: 2026-09-05T13:57:37.446375+00:00
- actor: claude-code
  id: 01m1rxrvqshxd2vbhkd6qpe1m2
  text: |-
    ### implement — changed
    - evidence: 1 file — `Sources/FoundationModelsACPClient/AgentProcess.swift`: in `createPipe()`, the cleanup loop `for open in descriptors { close(open) }` is now `for descriptor in descriptors { close(descriptor) }`. No other local name in the file shadows a global C function. The public API is unchanged. The finding in `## Review Findings (2026-09-05 08:51)` is checked. `swift test` (root): 224 tests in 20 suites passed, 0 failures, 0 warnings, 0 skipped. `swift test --package-path IntegrationTests`: 87 tests in 12 suites passed, 0 failures, 0 warnings, 0 skipped. `pgrep` finds no `cat` and no `sleep 300` after the runs.
    - next: /review
  timestamp: 2026-09-05T13:57:46.873591+00:00
- actor: claude-code
  id: 01m1rxy7pkr7he7wx4b9dpn9kc
  text: |-
    ### test — green
    - The test team ran a clean rebuild of both suites.
    - Root suite: `swift test` — 224 tests, 20 suites, 0 failures, 0 warnings, 0 skipped.
    - Nested suite: `swift test --package-path IntegrationTests` — 87 tests, 12 suites, 0 failures, 0 warnings, 0 skipped.
    - The test team ran `swift package clean` on both packages first, so each build was a full rebuild, not a cached one. No warning lines and no error lines appeared in either build log.
    - The test team checked for leftover `sleep 300` probe processes after both runs. None were found.
    - No worktree was made. No push. No commit.
    - next: send the card to review.
  timestamp: 2026-09-05T14:00:42.963685+00:00
position_column: doing
position_ordinal: '80'
title: AgentProcess.spawn lets a second agent inherit the first agent's pipe ends
---
## What

`AgentProcess.spawn` creates the two stdio pipes and then calls `posix_spawn`. A child that `posix_spawn` starts inherits every open descriptor of the host, unless the descriptor carries `FD_CLOEXEC`. The spawn closes the four pipe ends inside the NEW child with `posix_spawn_file_actions_addclose`, but a DIFFERENT child that another `AgentProcess` spawns at the same moment gets copies of this agent's pipe ends and keeps them.

Found while the teardown tests of ^c1ys406 ran in parallel: the `sleep` child of one test held a copy of the write end of the `cat` pipe of the other test, and the `cat` child did not get its EOF when the teardown closed the host's own copy.

## Why it matters

Two agents spawned in one host at the same time can each hold the other's stdin write end. Then `closeStandardInput()` and the teardown's stdin close do not reach the other agent as EOF until the first agent exits. The doctor's check 7 and the teardown of ^c1ys406 both depend on that EOF.

## What to do

- [x] Set `FD_CLOEXEC` on all four pipe ends in `AgentProcess.spawn` directly after `pipe(2)`, before `posix_spawn`. The `dup2` file actions still put the child's ends on descriptors 0 and 1, because `dup2` clears the flag on the new descriptor.
- [x] A unit test spawns two children at the same time and proves that a stdin close of the first one reaches it as EOF while the second one is alive.

## Files

- `Sources/FoundationModelsACPClient/AgentProcess.swift`, `AgentProcess.spawn(command:arguments:)` and `AgentProcess.createPipe()`
- `Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift` has the `FD_CLOEXEC` shape for the test helper.

## Review Findings (2026-09-05 08:51)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPClient/AgentProcess.swift:329` `swift/naming-clarity` — Loop variable `open` does not clarify its role and shadows the global `open()` function. In this cleanup path, the variable represents a file descriptor to close, not a state or property. The name should reflect its actual role. Rename to `fd` or `descriptor` to clarify the loop variable represents a file descriptor, not a descriptor state. For consistency with the outer loop, `descriptor` is preferred: `for descriptor in descriptors { close(descriptor) }`.
