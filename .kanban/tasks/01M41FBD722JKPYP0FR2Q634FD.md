---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m41k93mywtvspv8sfqecg8qq
  text: |-
    Research done.
    - `AgentProcess.spawnChild` sets only `POSIX_SPAWN_SETPGROUP`. It closes the four pipe ends with `addclose` file actions. A descriptor that another thread opened without `FD_CLOEXEC` (between `pipe` and `fcntl`) goes into the agent.
    - The test helper `spawnInThisProcessGroup` (AgentProcessTeardownTests.swift) has a second copy of the pipe + `FD_CLOEXEC` code and of the spawn attribute / argv / `posix_spawn` code. Plan: make `createPipe()` and the spawn call internal and shared, and give the spawn a process-group choice, so that the test helper calls the production code. No second copy stays.
    - With `POSIX_SPAWN_CLOEXEC_DEFAULT`, Darwin keeps only the descriptors that the file actions name (dup2 targets, `addinherit_np`). The `addclose` actions become redundant. Stderr needs `posix_spawn_file_actions_addinherit_np(STDERR_FILENO)`, because the doc of `AgentProcess` says that the agent keeps the stderr of the host.
    - Test plan (event, no sleep): the test opens a pipe WITHOUT `FD_CLOEXEC` (the state of a parallel thread inside the window), spawns an `AgentProcess` that runs `/bin/sh -c '[ -e /dev/fd/N ]'`, and reads the answer of the agent until end of file. Before the change the answer is "open". A second test checks that the agent still holds stderr.
  timestamp: 2026-10-03T19:18:58.462033+00:00
- actor: claude-code
  id: 01m41knn5paq3fn0756ak2ajbd
  text: |-
    Implementation done.
    - RED 1: `agentHoldsNoDescriptorThatLacksTheCloseOnExecFlag` (AgentProcessPipeInheritanceTests.swift). The test opens a pipe without `FD_CLOEXEC` and spawns a `/bin/sh` probe through `AgentProcess`. The probe answered "open" for both ends before the change. The answer is an event (the stdout of the agent until end of file), not a sleep.
    - GREEN 1 / RED 2: with only `POSIX_SPAWN_CLOEXEC_DEFAULT`, the guard test `agentKeepsTheStandardErrorOfThisProcess` failed ("closed"): the agent lost the stderr of the host.
    - GREEN 2: `posix_spawn_file_actions_addinherit_np(STDERR_FILENO)`.
    - Fold: `AgentProcess.spawnChild(command:arguments:descriptors:processGroup:)` and `AgentProcess.createPipe()` are now internal. New internal enum `ChildProcessGroup` (`.own` = `POSIX_SPAWN_SETPGROUP`, `.inherited` = no group flag). The test helper `spawnInThisProcessGroup` calls the production code; its copy of pipe/fcntl/attributes/argv/posix_spawn is gone. The `addclose` file actions and the `parentSideFdsToClose` parameter are gone, because `POSIX_SPAWN_CLOEXEC_DEFAULT` closes every descriptor that the file actions do not name. The private constants `childStdinDescriptor`/`childStdoutDescriptor` are replaced by `STDIN_FILENO`/`STDOUT_FILENO`.
    - Discovery: when the helper children keep the stderr of the runner and have no stdout, `cat` writes "cat: stdout: Bad file descriptor" at exit. The helper now gives them `/dev/null` as stdout.
    - Discovery (not changed, outside the card): when the host starts with descriptor 0 or 1 closed, `pipe(2)` can return 0 or 1, so a `dup2` source can equal its target. The behavior of Darwin for `FD_CLOEXEC` on `adddup2(fd, fd)` is not verified here. The old code was worse in that case (its `addclose` closed the source after the `dup2`).
    - `ARCHITECTURE.md` does not exist; no update.
  timestamp: 2026-10-03T19:25:49.622690+00:00
- actor: claude-code
  id: 01m41knrn5pb1nkrgrzwkw0zan
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPClient/AgentProcess.swift, Tests/FoundationModelsACPClientTests/AgentProcessPipeInheritanceTests.swift, Tests/FoundationModelsACPClientTests/AgentProcessTeardownTests.swift, Tests/FoundationModelsACPClientTests/StdioChild.swift. `swift build` complete; `swift test` 479 tests in 40 suites passed; `swift test --package-path IntegrationTests` 103 tests in 14 suites passed. Warnings: only the accepted MLX "missing creator" and the permitted `SessionUpdateAggregator` deprecation.
    - next: /review
  timestamp: 2026-10-03T19:25:53.189359+00:00
- actor: claude-code
  id: 01m41kwxamnndd9n0zvygabm3d
  text: |-
    ### test — green
    - evidence: swift build — complete, 0 errors. swift test x5 — each run 479 tests in 40 suites, 5 of 5 runs passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests — 103 tests in 14 suites passed, 0 failed, 0 skipped.
    - warnings: only the accepted MLX "missing creator for mutated node" warning. No other warning.
    - code change: none. No fix was needed.
    - next: review
  timestamp: 2026-10-03T19:29:47.348658+00:00
- actor: claude-code
  id: 01m41kxb6kxz5nz3ngq36khtz1
  text: |-
    ### commit — changed
    - evidence: one local commit, subject "fix(process): spawn the agent with POSIX_SPAWN_CLOEXEC_DEFAULT". It holds 4 source and test files and the .kanban files. The sha is in the git log. Nothing was pushed.
    - next: none
  timestamp: 2026-10-03T19:30:01.555215+00:00
- actor: claude-code
  id: 01m41m6hqgmy060t9v084hwzx0
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (b14f6fe); 1 finding (1 confirmed, 0 refuted) — Tests/FoundationModelsACPClientTests/AgentProcessPipeInheritanceTests.swift:106 (swift/immutability)
    - next: implement the open item in the Review Findings section, then review again.
  timestamp: 2026-10-03T19:35:03.152800+00:00
- actor: claude-code
  id: 01m41m6teqwwythdtzbxaxf0s2
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 4 files (AgentProcess.swift, AgentProcessPipeInheritanceTests.swift new, AgentProcessTeardownTests.swift, StdioChild.swift)
    - test: green — swift test 479/479 x5, IntegrationTests 103/103
    - commit: b14f6fe fix(process): spawn the agent with POSIX_SPAWN_CLOEXEC_DEFAULT
    - review: findings — Tests/FoundationModelsACPClientTests/AgentProcessPipeInheritanceTests.swift:106 (swift/immutability)
  timestamp: 2026-10-03T19:35:12.087318+00:00
- actor: claude-code
  id: 01m41mbf8808dd26yq0knj352m
  text: |-
    Finding swift/immutability fixed.
    - `descriptorProbeAnswer(for:)` in AgentProcessPipeInheritanceTests.swift: the `var answer = Data()` accumulator and its `for try await` loop are gone. The function now uses `let answer = try await bytes.reduce(into: Data()) { data, chunk in data.append(chunk) }`. The call stays in a `do`/`catch`, because the `outcome` closure does not throw; a stream error still gives `nil`.
    - Whole-file scan, and scan of the lines that this task added in AgentProcess.swift, AgentProcessTeardownTests.swift and StdioChild.swift: no other mutable accumulator. The remaining `var` items are C out-parameters (`var descriptors` for `pipe(2)`, `var fileActions`, `var attributes`), not accumulators.
    - Discovery (not changed, outside the finding): `descriptorProbeAnswer(for:)` is a top-level `private func`. The swift/immutability rule "A function belongs to a type" can apply to it. The review did not report it.
    - TDD: this is a refactor with no behavior change. The two tests `agentHoldsNoDescriptorThatLacksTheCloseOnExecFlag` and `agentKeepsTheStandardErrorOfThisProcess` cover it and pass.
  timestamp: 2026-10-03T19:37:44.456807+00:00
- actor: claude-code
  id: 01m41mbghfp60qa4ewmx5hcsjf
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPClientTests/AgentProcessPipeInheritanceTests.swift. `swift build` complete; `swift test` 479 tests in 40 suites passed, 0 failed. Warnings: only the accepted MLX "missing creator for mutated node".
    - next: /review
  timestamp: 2026-10-03T19:37:45.775040+00:00
- actor: claude-code
  id: 01m41mffrhqg0031xbc4925pdz
  text: |-
    ### test — green
    - evidence: swift build ok. swift test: 479 tests in 40 suites passed. swift test --package-path IntegrationTests: 103 tests in 14 suites passed. 0 failures, 0 skipped. Only warning: accepted SwiftPM "missing creator for mutated node" (mlx-swift).
    - next: review
  timestamp: 2026-10-03T19:39:56.049923+00:00
- actor: claude-code
  id: 01m41mft51w3vyk91mht5pk4e2
  text: |-
    ### commit — changed
    - evidence: commit "test(process): read the descriptor probe answer with reduce(into:)" (sha in git log of this branch)
    - next: review
  timestamp: 2026-10-03T19:40:06.689585+00:00
position_column: doing
position_ordinal: '8180'
title: 'AgentProcess.spawn: close the pipe()/fcntl window with POSIX_SPAWN_CLOEXEC_DEFAULT'
---
## What
`AgentProcess.createPipe()` in `Sources/FoundationModelsACPClient/AgentProcess.swift` calls `pipe(2)` and then sets `FD_CLOEXEC` with `fcntl`. Its doc says: "The flag goes on both ends here, directly after `pipe(2)` and before any spawn on any thread, so no child can inherit either end." That is not true. Another thread can call `posix_spawn` between the `pipe` call and the `fcntl` call. That child then holds a copy of the write end of the agent's stdin. The agent reads no end of file after `closeStandardInput()` until that other child exits.

Found during ^h5z930j: the test helper `spawnInThisProcessGroup` had the same window, and it now uses `POSIX_SPAWN_CLOEXEC_DEFAULT`.

- [x] Add `POSIX_SPAWN_CLOEXEC_DEFAULT` to the spawn attributes in `AgentProcess.spawnChild`, beside `POSIX_SPAWN_SETPGROUP`. Then the child holds only the descriptors the file actions name (0 and 1), whatever a parallel thread does. Check that stderr of the agent still reaches the host: add `posix_spawn_file_actions_addinherit_np` for `STDERR_FILENO` if the agent must keep it.
- [x] Correct the doc of `createPipe()`: the flag alone does not close the race.
- [x] Write a failing test first (`/tdd`).

## Acceptance Criteria
- [x] A child of `AgentProcess.spawn` holds no descriptor of this process except its stdin, stdout and (if kept) stderr.
- [x] `swift test` passes.

## Review Findings (2026-10-03 14:30)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsACPClientTests/AgentProcessPipeInheritanceTests.swift:106` `swift/immutability` — Build a collection with `reduce`, not a mutable accumulator variable. The accumulator is mutable for the whole loop, making it harder to understand at a glance what value gets constructed. Replace with `let answer = try await bytes.reduce(into: Data()) { data, chunk in data.append(chunk) }`, moving the reduce call outside the try-catch as `let answer = try await bytes.reduce(into: Data()) { data, chunk in data.append(chunk) }` (the async stream's error propagates through `try await`, so error handling stays the same).
