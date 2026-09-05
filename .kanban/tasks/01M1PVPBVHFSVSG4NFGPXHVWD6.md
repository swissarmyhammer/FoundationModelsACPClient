---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rz1t49266f70djxst3yahv
  text: |-
    Research, before the change.

    - `AgentProcessTests.swift` holds a private `writeScript(_:)`. It writes `acp-agent-<UUID>.sh` into the temporary directory. Four tests call it, and no test removes the file. The test `agentChildProcessIsCleanedUpWithTheGroup` also names `acp-agent-child-<UUID>.pid` by hand, and no test removes that file.
    - `Support/StubAgents.swift` gives `writeAgentScript(_:)` (prefix `acp-stub-agent-`, suffix `.sh`) and `removeAgentScript(_:)`. `Support/TemporaryFiles.swift` gives `writeTemporaryFile(_:prefix:suffix:)` and `temporaryFileURL(prefix:suffix:)`.
    - The other suites use one shape: `let pidFile = temporaryFileURL(prefix: Self.pidFileNamePrefix)` then `defer { try? FileManager.default.removeItem(at: pidFile) }`, and `let script = try make...Agent(...)` then `defer { removeAgentScript(script) }`. Each suite holds a private static `pidFileNamePrefix` constant with a doc comment.

    Measurement, before the change. `TMPDIR` is `/var/folders/3k/6b488x1j6rg1f6w8fnyfwm9w0000gn/T/`.

    - Before any run: 385 `acp-agent-*` entries (308 `acp-agent-*.sh`, 77 `acp-agent-child-*.pid`). These came from earlier runs.
    - `swift test --package-path IntegrationTests`: 87 tests in 12 suites passed, exit 0.
    - After that one run: 390 entries (312 `.sh`, 78 `.pid`). One run leaks 5 files: 4 scripts and 1 child pid file.

    Plan: delete `writeScript(_:)`, call `writeAgentScript(_:)` with `defer { removeAgentScript(script) }` in each of the four tests, and name the child pid file with `temporaryFileURL(prefix:)` beside a `defer` that removes it. No assertion changes.
  timestamp: 2026-09-05T14:20:08.713978+00:00
- actor: claude-code
  id: 01m1rz66sb3vpenevmdxfady4c
  text: |-
    ### implement — changed

    - evidence: 1 file — `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentProcessTests.swift`. The private `writeScript(_:)` is deleted. The four tests call `writeAgentScript(_:)` and remove the script with `defer { removeAgentScript(script) }`. The test `agentChildProcessIsCleanedUpWithTheGroup` names its child pid file with `temporaryFileURL(prefix: Self.childPidFileNamePrefix)` and removes it with `defer { try? FileManager.default.removeItem(at: childPidFile) }`. The suite holds one new private static constant, `childPidFileNamePrefix = "acp-agent-child-pid-"`, in the shape the other suites use. No assertion changed.
    - leak, before: 385 `acp-agent-*` files stood in `TMPDIR` from earlier runs (308 `.sh`, 77 `child-*.pid`). One integration run, before the change, took the count to 390: 4 scripts and 1 child pid file for each run.
    - leak, after: I deleted the 385 pre-existing `acp-agent-*` files from `TMPDIR` before the after-measurement, so the number is honest. Count before the run: 0. Count after `swift test --package-path IntegrationTests`: 0.
    - discovery: `TMPDIR` also holds 3 `acp-stub-agent-*.sh` and 3 `acp-client-no-leak-agent-pid-*` files from an earlier run. The count was 3 and 3 before this run and 3 and 3 after it, so this run wrote none of them. They are outside this card.
    - tests: `swift test` (root): 225 tests in 20 suites passed, 0 failures, 0 warnings, 0 skipped. `swift test --package-path IntegrationTests`: 87 tests in 12 suites passed, 0 failures, 0 warnings, 0 skipped. `swift build --package-path IntegrationTests --build-tests` reports 0 warnings.
    - next: `/review`. Not committed.
  timestamp: 2026-09-05T14:22:32.747684+00:00
- actor: claude-code
  id: 01m1rzbf79s2n7961fkjaz8z1c
  text: |-
    ### test — green

    - The command `swift test` did run. The result was 225 tests in 20 suites. All tests did pass. No test did fail. No test did skip. No warning did show.
    - The command `swift test --package-path IntegrationTests` did run. The result was 87 tests in 12 suites. All tests did pass. No test did fail. No test did skip. No warning did show.
    - After the integration run, the check of the temporary directory (`$TMPDIR`) did find 0 files with the name `acp-agent-*`. The suite did leave no script file and no pid file.
    - The outcome is green.
  timestamp: 2026-09-05T14:25:25.225160+00:00
- actor: claude-code
  id: 01m1rzcmtpv37bphj0cftxed3n
  text: |-
    ### commit — changed
    - evidence: 754cd8c test(integration): remove leaked temp files from AgentProcess tests
    - next: none
  timestamp: 2026-09-05T14:26:03.734046+00:00
- actor: claude-code
  id: 01m1rzfap8rrxpv807mkxmse90
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 754cd8c). 1 file reviewed, 7 validator runs, 0 findings, 0 confirmed, 0 refuted. The 4 files under `.kanban/` were not reviewed because of `.reviewignore`.
    - next: none. The task moved from `review` to `done`.
  timestamp: 2026-09-05T14:27:31.656965+00:00
- actor: claude-code
  id: 01m1rzfxmj1r3ea61k83v8rdeh
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — `IntegrationTests/.../AgentProcessTests.swift`: private `writeScript(_:)` deleted; the four tests use `writeAgentScript(_:)` with `defer { removeAgentScript }`; the child pid file uses `temporaryFileURL(prefix:)` with a `defer` removal. Leak measured: 5 `acp-agent-*` files per run before, 0 after.
    - test: green — root 225/225 in 20 suites, integration 87/87 in 12 suites, 0 warnings, 0 skipped; `acp-agent-*` count 0 before and after the run
    - commit: 754cd8c
    - review: clean — 0 findings; task moved to `done`
  timestamp: 2026-09-05T14:27:51.058766+00:00
position_column: done
position_ordinal: ad80
title: Fold AgentProcessTests onto the shared temporary-file writer, and remove the scripts it leaves
---
## What

`IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentProcessTests.swift`
holds a private `writeScript(_:)`. It is a near-copy of the writer that
`Support/StubAgents.swift` now shares:
`Support/TemporaryFiles.swift` gives
`writeTemporaryFile(_:prefix:suffix:)`, and `writeAgentScript(_:)` and
`writeStandardInputFile(_:)` both call it.

`AgentProcessTests.swift` stood outside the change that made the shared writer,
so the duplication rule kept the fix on the changed side. This card is the
other half.

Two things to do:

- Delete the private `writeScript(_:)` from `AgentProcessTests.swift` and call
  `writeAgentScript(_:)` in its place, or call
  `writeTemporaryFile(_:prefix:suffix:)` directly when the `acp-agent-` prefix
  is worth keeping.
- Remove each script the tests write. Measured after a full run, the temporary
  directory holds many `acp-agent-*.sh` files and several
  `acp-agent-child-*.pid` files, because no test removes what it wrote. The
  stub-agent tests already do this with `defer { removeAgentScript(script) }`;
  follow that shape.

## Acceptance Criteria

- [x] `AgentProcessTests.swift` holds no temporary-file writer of its own.
- [x] After `swift test --package-path IntegrationTests`, the temporary
      directory holds no `acp-agent-*` file.
- [x] Every assertion in the integration suite still passes.

## Tests

- [x] Run `swift test --package-path IntegrationTests`, then list the
      temporary directory and confirm it holds nothing the run wrote.
