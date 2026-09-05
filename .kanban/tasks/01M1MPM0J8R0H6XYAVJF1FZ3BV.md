---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1qrynkcem3daytzyeje5xe1
  text: |-
    ### Research — what §11 already covers, and what it does not

    **Path correction.** The card was written before the CLI moved. The CLI now lives in
    `Sources/AcpClientCore/`, not `Sources/acp-client/`. The test paths on the card are still
    correct: `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/`.

    **Already proven with a real pid (do not repeat):**

    | Path | Where |
    |---|---|
    | `run` — `end_turn`, `refusal`, `cancelled`, idle with no stop reason | `RunCommandExitTests.noAgentProcessOutlivesTheRun` |
    | `run` — `--timeout` reached, exit 124 | `TimeoutTests.noAgentProcessOutlivesATimeout` |
    | `run` — one Ctrl-C, exit 4 | `InterruptTests.noAgentProcessOutlivesACancelledRun` |
    | `run` — two Ctrl-C, exit 4 | `InterruptTests.twoInterruptsEndARunWhoseAgentIgnoresTheCancellation` |
    | `probe` — the agent answers | `ProbeCommandTests.noAgentProcessOutlivesTheProbe(initializes: true)` |
    | `probe` — the agent refuses `initialize` | `ProbeCommandTests.noAgentProcessOutlivesTheProbe(initializes: false)` |
    | `doctor` (the `Doctorable`, not the binary) — every row passes | `AgentCommandDoctorTests.noAgentProcessOutlivesTheChecks` |
    | `doctor` (the `Doctorable`) — the initialize row times out | `...AfterATimeout` |
    | `doctor` (the `Doctorable`) — the version row fails | `...AfterAVersionMismatch` |
    | `doctor` (the `Doctorable`) — the agent lingers, and the agent leaves a child | the two teardown-row tests |
    | `AgentProcess` (the library) — a grandchild dies with the group | `AgentProcessTests.agentChildProcessIsCleanedUpWithTheGroup` |

    **Not covered, and to be added:**

    1. `run` — the agent goes away in the middle of the turn. `TimeoutTests` asserts exit 1 and
       the elapsed time, and it reads no pid.
    2. `run` — the agent refuses `session/new`. No stub for this exists yet. It is the one
       protocol failure that lands AFTER the spawn and BEFORE the turn.
    3. `run` — a grandchild of the agent, through the BINARY. Only the library is proven today.
    4. `run` — the spawn itself fails. See the finding below.
    5. `probe` — the agent refuses `session/new`.
    6. `probe` — the agent never reports a command list, so the bounded wait ends first.
    7. `probe` — the agent does not implement `session/close`.
    8. `probe` — the agent goes away the moment it starts.
    9. `doctor` — the BINARY. `DoctorCommandTests` reads no pid on any row.

    **Finding: a `--cwd` that does not resolve is not reachable from the command line.**
    `AgentSession.sessionWorkingDirectory(for:)` makes every `--cwd` value absolute against the
    process working directory with `URL(fileURLWithPath:relativeTo:).standardizedFileURL`, and
    `AbsolutePath.init?(rawValue:)` refuses only a string that does not start with `/`. So
    `SessionWorkingDirectoryError` cannot be thrown by any command line. There is no exit path
    to sweep. A separate task records the question.

    **Finding: a spawn failure IS reachable.** `AgentCommandResolver` accepts any executable
    regular file, and `posix_spawn` answers `ENOEXEC` for a file that is not an executable
    format. Measured: `os.posix_spawn` on an executable text file gives errno 8. No child is
    made, so there is no pid to read; the row is written as "the failure leaves nothing behind,
    and the next run still works".

    **Finding: the `waitpid` instrument the card names cannot fail.** `waitpid` answers `ECHILD`
    for every pid that is not a child of the caller. The stub agent is a child of `acp-client`
    and a GRANDCHILD of the test, so `waitpid` from the test answers `ECHILD` whether the agent
    is alive or dead. Such an assertion states nothing. The zombie claim is written instead as
    the mid-turn-death row plus the grandchild row: `processExists(_:)` reads `kill(pid, 0)`,
    which still reaches a zombie, so a pid that is gone is a pid that was reaped.
  timestamp: 2026-09-05T03:14:19.884646+00:00
- actor: claude-code
  id: 01m1qtqrhxxdrwc8qrpqnkqnp4
  text: |-
    ### The RED, which was watched twice

    The sweep asserts behaviour that already works, so each half was made to fail
    before it was believed. Each mutation saved the working file first and restored
    from that copy in the same shell command; `git status --porcelain -- Sources`
    was empty after each restore.

    **The exit-code half.** `AcpClientExitCode.forError(_:)` was made to answer
    `.success` for every error. 13 issues, in 10.5 s, each naming its own path:

        run, against an agent that goes away in the middle of the turn exited 0 rather than 1
        run, against an agent that refuses session/new exited 0 rather than 1
        probe, against an agent that refuses session/new exited 0 rather than 1
        probe, against an agent that ends the moment it starts exited 0 rather than 1

    plus `aFailedSpawnLeavesNothingBehind`. All three tests failed; the doctor rows
    stayed green, because a doctor verdict comes from `forDoctorStatus(_:)` and not
    from `forError(_:)`.

    **The group-kill half.** `killpg(taken.pid, SIGKILL)` in
    `AgentProcessState.terminateCurrent()` was made `kill(taken.pid, SIGKILL)`. The
    whole suite takes 10.4 s unmutated; under the mutation
    `runReachesAnAgentThatLeftAChild` started and had not returned after 240 s. So
    that row rests on the group kill and on nothing else.

    ### The defect the mutation uncovered

    The group-kill mutation did not merely fail the row — it HUNG the binary, and
    that is a real fragility in production code rather than in the test.
    `AgentProcessState.terminateCurrent()` calls `waitpid` with a blocking wait
    BEFORE it closes the agent's stdin, so a `killpg` that misses leaves the wait
    with nothing that can ever end it. Recorded as task ^c1ys406.

    The leaked grandchild also inherits the agent's stderr, which is the binary's
    own stderr pipe, so `runAcpClient` cannot drain that pipe either. A regression
    of the group kill therefore reads as the suite's five-minute time limit rather
    than as a named row. That is a slow red, and it is still a red.

    ### What was added to the support file

    `StubAgents.swift`:

    - `makeNewSessionRefusingAgent(pidFile:)` and `makeSessionCloseRefusingAgent(pidFile:)`,
      behind a new `StubAgentRequestAnswer` and the `newSession:`/`closeSession:`
      parameters of `requestLoop`.
    - `makeUnexecutableAgentBinary()`, an executable regular file that is not an
      executable format, which is the one shape that reaches `posix_spawn` and
      gets `ENOEXEC`.
    - A pid file on `makeExitingAtOnceAgent(pidFile:)` and
      `makeBannerOnStdoutAgent(pidFile:)`.
    - `agentCommandArguments(_:options:script:)`, the one command-line builder for
      the three subcommands, with `runSubcommandName`, `probeSubcommandName`,
      `doctorSubcommandName` and `agentCommandSeparator` beside it.
      `runArguments(prompt:options:script:)` now calls it. See ^cen6s76.
    - `stubAgentChildLeavingPidCount`, which replaced a private copy in
      `AgentCommandDoctorTests`.
    - Three JSON-RPC error builders folded onto one `requestError(id:code:message:)`.
  timestamp: 2026-09-05T03:45:30.685925+00:00
- actor: claude-code
  id: 01m1qtr04rkrty92y63ndt5fp1
  text: |-
    ### implement — changed
    - evidence: 3 files —
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/NoLeakedAgentTests.swift` (new),
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift`,
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`.
      `swift test` — 215 tests in 17 suites, passed, 0.7 s.
      `swift test --package-path IntegrationTests` — 75 tests in 12 suites, passed,
      19.1 s. No warnings in either.
      RED was watched on both halves before GREEN; the two mutations and their
      restores are in the comment above.
      Paths already covered: 12 rows, listed in the description. Paths added: 11
      rows, listed in the description. Two paths were found not to exist, and each
      is stated with its reason.
    - next: `/review`. Two new tasks came out of the work: ^x71mrtr (`--cwd` has no
      reachable failure) and ^c1ys406 (the teardown blocks when the group kill
      misses). ^cen6s76 was narrowed by a comment.
  timestamp: 2026-09-05T03:45:38.456412+00:00
- actor: claude-code
  id: 01m1qv8651yep6adv27dkff62v
  text: |
    ### review — findings
    - scope: `review sha d08d44b~1..d08d44b`, 3 source files, `.kanban/` excluded
    - engine: 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed
    - directed verification raised 3 findings, all on added lines of `NoLeakedAgentTests.swift`: lines 39, 85 and 63
    - verified TRUE: the `waitpid`/`ECHILD` reasoning; `kill(pid, 0)` reaches a zombie; all 12 "already covered" rows exist by name; `--cwd` cannot fail from a command line; no usage error can follow a spawn
    - verified FALSE: that the zombie row bites. A parent that exits hands its unreaped children to `launchd`, which reaps them at once, so a reading taken after `acp-client` exits cannot tell a reap from a leak
    - ^c1ys406 is correctly separate work: `Sources/FoundationModelsACPClient/AgentProcess.swift` is not in this delta, and a defect on an unchanged line is not a finding under a diff op
    - evidence left clean: no file under `Sources/`, `Tests/` or `IntegrationTests/` was modified, and no `swift-test` process runs
    - next: correct the three claims, then re-review
  timestamp: 2026-09-05T03:54:28.897453+00:00
- actor: claude-code
  id: 01m1qv9hmbdyf5w7kf8b41ye8e
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 files. 11 new §11 rows; 12 already-covered rows deliberately not repeated; two paths proven not to exist.
    - test: green — root 215 passed in 17 suites, integration 75 passed in 12 suites, 0 warnings
    - commit: d08d44b test(integration): prove no agent process outlives the run
    - review: findings — NoLeakedAgentTests.swift:39, :63, :85

    The review verified the map: all 12 "already covered" rows exist by name elsewhere, the 11 added rows are present, and no exit path is missing from both lists. Both "does not exist" claims are true — `sessionWorkingDirectory(for:)` always builds an absolute path, and the prompt resolves at RunCommand.swift:105 while the spawn is at :192, so no usage error can follow a spawn.

    The finding that matters is a measured one. The implementer's `waitpid` reasoning is right — the stub agent is a grandchild, so `waitpid` from the test answers the same either way — but the conclusion does not follow. The reading is taken AFTER `acp-client` exits, and a parent that exits hands its unreaped children to `launchd`, which reaps them at once. Measured:
    - while the parent still runs, the unreaped child is REACHABLE
    - after the parent exited, the same pid is GONE (ESRCH)

    So `processExists` is sound for "still alive" and CANNOT FAIL for "was reaped" — the same defect the file header raises against `waitpid`. The acceptance row "is reaped, not left as a zombie" is asserted by nothing.

    The second finding explains something this session already paid for. `killpg`→`kill` did not make a test FAIL; it made one hang for 240 s. `runAcpClient` SIGKILLs only `acp-client` on its bound, and `AgentProcess.spawnChild` redirects only descriptors 0 and 1, so a surviving agent inherits and holds open the harness's stderr write end, and `FileHandle.readToEnd()` never returns. A leaked agent WEDGES the suite instead of failing it — which is exactly the wedged `swift-test` processes an earlier review left behind on this board.

    ^c1ys406 is genuinely separate: `AgentProcess.swift` is outside this commit's delta.
  timestamp: 2026-09-05T03:55:13.419189+00:00
- actor: claude-code
  id: 01m1qvygak3crc5d447jqdbf5n
  text: |
    ### Picked the card back up from `review`, and measured both findings

    **Baseline.** `swift test --package-path IntegrationTests --filter NoLeakedAgentTests`
    — 3 tests in 1 suite, passed, 10.5 s.

    **Finding at :63 reproduced (the harness wedge).** The `killpg`→`kill` mutation
    of `AgentProcessState.terminateCurrent()` was applied again, and the suite was
    run under `timeout 180`. It printed NOT ONE test line and `timeout` killed it at
    180 s (exit 124). So the leak really does read as a hang and not as a row. The
    file was restored from a copy saved in the same shell command, and
    `git status --porcelain` showed no source file changed.

    **Finding at :39 and :85 confirmed, and the seam that DOES carry the reap was
    found.** `AgentProcessTests.killingAgentSurfacesDisconnectedState` is the test
    that bites: `AgentProcess` spawns the agent from the TEST process, so the test
    is the agent's parent and it stays alive to take the reading. Measured with a
    second mutation — `waitpid` removed from `terminateCurrent()`, the `killpg`
    left in place:

        killingAgentSurfacesDisconnectedState ... failed at AgentProcessTests.swift:140
        spawnedAgentLeavesNoStrayPidAfterTeardown ... failed at :157
        agentChildProcessIsCleanedUpWithTheGroup ... failed at :181
        fullSessionOverStdioToForeignAgent ... failed
        4 tests, 4 issues, 40.1 s

    Every one of those four is `!processExists(pid)` on a pid that the mutation
    leaves as a ZOMBIE. So the reap claim is carried, and it is carried where it can
    be: inside the parent. Restored from a copy in the same command; `git status`
    clean.

    **What follows for the mid-turn row.** The reap cannot be asserted from
    `NoLeakedAgentTests` at all. `AgentProcess` reaps on the EOF branch of its
    reader thread, which runs microseconds before `acp-client` exits, so there is no
    window a poll from outside can catch. Holding the binary open longer does not
    help either: the only way to keep it open past the agent's death is a grandchild
    holding the stdout pipe, and on that path a zombie is the CORRECT behaviour
    until teardown. So the row changes to name the seam that proves it.
  timestamp: 2026-09-05T04:06:40.211290+00:00
- actor: claude-code
  id: 01m1qwaph3bmvw8s8trh6snj2w
  text: |
    ### What each finding got, and how each was proven

    **:63, the harness wedge.** The finding offered two ways. The FIRST is not open
    to this harness: `Process` gives `acp-client` the TEST RUNNER's own process
    group, so a `killpg` on the bound would kill the test runner. The second way is
    taken. `Support/CLITestSupport.swift` now holds `PipeDrain`, which installs a
    readability handler on each of the run's two pipes and takes the bytes as they
    arrive, and `bytes(waitingUpTo:)`, which waits for the end of file and gives up
    at `pipeDrainGrace` (2 s) after the run ended. `readToEnd(_:)` and
    `drainedBytes(from:)` are deleted. `exited(_:within:)` now goes through one new
    `polled(within:until:)`, so the file keeps ONE poll loop rather than two.
    `DrainedPipe` carries the shared state in a `Mutex`, for the reason
    `AgentProcessState` does: a readability handler cannot await.

    Two new tests in `CLITestSupportTests` hold the two halves:
    `theDrainGivesBackWhatArrivedWhileAWriterStillHoldsThePipe` (the bytes come
    back, and the drain really waited out its grace) and
    `theDrainEndsWhenTheLastWriterCloses` (the bytes come back BEFORE the grace
    ends, so a healthy run pays none of it).

    **:39 and :85, the zombie claim.** The reap cannot be measured while the binary
    runs. `AgentProcess` reaps on the EOF branch of its reader thread, which runs
    microseconds before `acp-client` exits, and the only way to hold the binary open
    past the agent's death is a grandchild holding the stdout pipe — on that path a
    zombie is the CORRECT state until teardown, so nothing honest can be asserted
    there either. So the card takes the other option the finding names. The file
    header now opens "**This file claims no reap, and it cannot.**" and states the
    `launchd` reparenting, the measurement, and the seam that does carry the reap.
    The case doc of `runReachesAnAgentThatGoesAwayMidTurn` no longer claims a
    `waitpid` the row cannot see. The acceptance row and the Tests row on the card
    changed to match.

    ### The re-run mutation, which is the proof for :63

    `killpg`→`kill` in `AgentProcessState.terminateCurrent()`, the same mutation as
    before:

    - BEFORE the fix: no test line printed at all, and `timeout` killed the run at
      180 s (exit 124).
    - AFTER the fix: **failed in 16.5 s with 3 issues**, each naming its pid —
      `the process with pid 66357 outlived run, against an agent that leaves a child behind`.

    The file was saved and restored in the same shell command both times, and
    `git status --porcelain` after each restore showed no change under `Sources/`.
    `pgrep -fl "swift-test|swiftpm-testing-helper|xctest|acp-stub-agent|acp-client"`
    answered `none` after each.
  timestamp: 2026-09-05T04:13:19.779754+00:00
- actor: claude-code
  id: 01m1qwc05v48hv26tz8f7k7y52
  text: "### implement — changed\n- evidence: 3 files —\n  `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/CLITestSupport.swift`\n  (the bounded `PipeDrain`, `DrainedPipe`, `pipeDrainGrace`, the one\n  `polled(within:until:)`; `readToEnd(_:)` and `drainedBytes(from:)` deleted),\n  `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/CLITestSupportTests.swift`\n  (two new drain tests),\n  `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/NoLeakedAgentTests.swift`\n  (the header, the `noLeakRunBound` doc, and the mid-turn case doc).\n  `swift test` — 215 tests in 17 suites, passed. \n  `swift test --package-path IntegrationTests` — 77 tests in 12 suites, passed,\n  19.1 s. No warnings in either package.\n  Finding :63 proven fixed by the re-run mutation: `killpg`→`kill` now FAILS in\n  16.5 s with 3 named issues, where before the fix it printed nothing and was\n  killed at 180 s.\n  Findings :39 and :85 proven by the second mutation: `waitpid` removed from\n  `terminateCurrent()` reds 4 `AgentProcessTests` rows, which is the seam the\n  card now names for the reap.\n  All three review findings are checked, and the acceptance row and the Tests\n  row that carried the unassertable zombie claim were changed.\n- next: `/review`.\n"
  timestamp: 2026-09-05T04:14:02.427696+00:00
- actor: claude-code
  id: 01m1qwsqe2z8h3ry7ry57kka7a
  text: |
    ### review — clean

    - evidence: `review sha 1186896~1..1186896`, 7 validators attempted, 0 findings, 0 confirmed, 0 refuted. 3 files reviewed, 2 skipped (`.kanban/`, from `.reviewignore`). All three prior findings are checked and genuinely fixed. Directed verification of the four judgement points found no new defect. `timeout 900 swift test --package-path IntegrationTests` — 77 tests in 12 suites, 19.07 s, 0 failures, 0 warnings. Working tree clean, no stray test process.
    - next: none. Task moved to `done`.
  timestamp: 2026-09-05T04:21:32.226287+00:00
- actor: claude-code
  id: 01m1qwtz69ew41gx9hftm0qbta
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 3 files. The harness drains both pipes as the bytes arrive; the zombie claim was rewritten rather than left unassertable.
    - test: green — root 215 passed in 17 suites, integration 77 passed in 12 suites in 19.1 s, 0 warnings
    - commit: 1186896 fix(integration): drain CLI test pipes as bytes arrive to stop leak-wedged suites
    - review: clean — zero new findings, task moved to done

    The pipe-drain fix is the one that pays back beyond this card. A leaked agent used to inherit and hold open the harness's stderr write end, and `FileHandle.readToEnd()` is synchronous and non-cancellable, so a leak WEDGED the suite instead of failing it. Proven both ways: the `killpg`→`kill` mutation hung until killed at 180 s before the fix, and now fails in 16.5 s naming the pid that outlived the run. That is the same failure mode that wedged two `swift-test` processes on this board earlier.

    The review checked the drain carefully and found it sound: no lost bytes (the kernel buffer holds what arrives before the handler is installed, and the end-of-file flag is set under the same lock that appends), no data race, no handler left installed (two closings, both needed, because Foundation keeps calling a handler after end of file), and the 2-second grace cannot truncate a legitimate slow write — it begins only after the binary has already exited, so the only process that could still hold a write end is a leaked descendant.

    The zombie claim is now honest. It cannot be measured from that sweep at all: `launchd` reaps an orphan the moment its parent exits. The acceptance row names `AgentProcessTests.killingAgentSurfacesDisconnectedState` instead, where the test process IS the agent's parent and stays alive to take the reading, and the file header opens by denying the claim outright and giving the reason.

    44 call sites were checked: the bytes are identical in the non-leak case, `standardError` no longer throws (which narrows what callers must handle), and the bound grew by two graces, still under the suite backstop.
  timestamp: 2026-09-05T04:22:12.937294+00:00
depends_on:
- 01M1MPG0WT31XJVP37C3CAT35C
- 01M1MPJRCZKG9CEZ7N5TDX6EDK
- 01M1MPKCCB56CA910R6JA5XSFA
position_column: done
position_ordinal: a280
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

## Path check

The paths in the "What" section above were checked and are CORRECT. The CLI
source moved to `Sources/AcpClientCore/`, but no path in this description names
the CLI source, so nothing here needed a correction.

## Acceptance Criteria

- [x] Each of the six exit paths leaves no agent process.
- [x] A grandchild of the agent is gone too.
- [x] An agent that dies in the middle of a turn gives exit 1, and no process
      outlives the run.
      **The row changed, because the old wording claimed what nothing checks.**
      It read "and is reaped, not left as a zombie". That cannot be asserted
      from outside the run at all: every reading of `NoLeakedAgentTests` is
      taken AFTER `acp-client` exits, and a parent that exits hands its
      unreaped children to `launchd`, which reaps them at once — so the pid is
      gone whether or not `acp-client` reaped it. Measured: while the parent
      still runs, an unreaped child is REACHABLE; after the parent exits, the
      same pid answers `ESRCH`. The reap is proven where the reader IS the
      parent and stays alive to take the reading:
      `AgentProcessTests.killingAgentSurfacesDisconnectedState`. See the Tests
      section.
- [x] The suite fails loudly, naming the pid and the exit path, when a process
      is still alive. Proven by mutation, twice: see the Tests section.

## Tests

- [x] `NoLeakedAgentTests.swift`, one test per acceptance row above.
- [x] The reap is asserted where it can be:
      `AgentProcessTests.killingAgentSurfacesDisconnectedState` kills the agent
      that `AgentProcess` spawned from the TEST process and then asserts the
      pid is gone. The test is the agent's parent and it stays alive to take
      the reading, so a pid left as a ZOMBIE fails the assertion.
      **Measured with the `waitpid` taken out of
      `AgentProcessState.terminateCurrent()`**: that row and its three
      neighbours in `AgentProcessTests` all go red — 4 tests, 4 issues, 40.1 s.
      `waitpid` was refused as the instrument, and the reasoning stands:
      `waitpid` answers `ECHILD` for every pid that is not a child of the
      caller, and the stub agent is a child of `acp-client` and a GRANDCHILD of
      the test process. `processExists(_:)` reads `kill(pid, 0)`, which is
      sound for "is anything STILL ALIVE" and cannot fail for the reap. The
      file header of `NoLeakedAgentTests.swift` states the whole argument and
      names the seam that carries the reap.
- [x] One test runs the whole set twice in a row and asserts the second run is
      unaffected by the first, which catches a leaked descriptor.
- [x] A LEAKED agent fails the suite as a leak, and never wedges it.
      `AgentProcess` redirects only descriptors 0 and 1, so a surviving agent
      holds the harness's own stderr write end open, and
      `FileHandle.readToEnd()` waits for every write end to close with no
      cancellation reaching it. `runAcpClient` reads both pipes as the bytes
      ARRIVE — `PipeDrain` in `Support/CLITestSupport.swift` — and gives up at
      `pipeDrainGrace` (2 s) after the run ended. Two tests in
      `CLITestSupportTests` hold the two halves of that claim: a drain whose
      writer still holds the pipe hands back what arrived, and a drain whose
      writer closed ends before its grace.
- [x] Run `swift test --package-path IntegrationTests`. Every assertion
      passes. 77 tests in 12 suites, 19.1 s. The root `swift test` also passes:
      215 tests in 17 suites. No warnings in either.

## The complete §11 map

Every exit path of every subcommand, and where its pid is read.

### Already covered before this card

| The path | Where |
|---|---|
| `run` — `end_turn`, `refusal`, `cancelled`, idle with no stop reason | `RunCommandExitTests.noAgentProcessOutlivesTheRun` |
| `run` — the limit of `--timeout`, exit 124 | `TimeoutTests.noAgentProcessOutlivesATimeout` |
| `run` — one Ctrl-C, exit 4 | `InterruptTests.noAgentProcessOutlivesACancelledRun` |
| `run` — two Ctrl-C, exit 4 | `InterruptTests.twoInterruptsEndARunWhoseAgentIgnoresTheCancellation` |
| `probe` — the agent answers | `ProbeCommandTests.noAgentProcessOutlivesTheProbe(initializes: true)` |
| `probe` — the agent refuses `initialize` | `ProbeCommandTests.noAgentProcessOutlivesTheProbe(initializes: false)` |
| `doctor` CHECKS — every row passes | `AgentCommandDoctorTests.noAgentProcessOutlivesTheChecks` |
| `doctor` CHECKS — the initialize row times out | `...AfterATimeout` |
| `doctor` CHECKS — the version row fails | `...AfterAVersionMismatch` |
| `doctor` CHECKS — the agent lingers | `anAgentThatIgnoresAClosedStdinWarnsOnTheTeardownRow` |
| `doctor` CHECKS — the agent leaves a child | `anAgentThatLeavesAChildWarnsOnTheTeardownRow` |
| `AgentProcess` (the library) — a grandchild | `AgentProcessTests.agentChildProcessIsCleanedUpWithTheGroup` |
| `AgentProcess` (the library) — the REAP of a dead agent | `AgentProcessTests.killingAgentSurfacesDisconnectedState` |

### Added by this card, in `NoLeakedAgentTests.swift`

| The path | Exit code | Row |
|---|---|---|
| `run` — the agent goes away in the middle of the turn | 1 | `runReachesAnAgentThatGoesAwayMidTurn` |
| `run` — the agent refuses `session/new` | 1 | `runReachesAnAgentThatRefusesTheSession` |
| `run` — the agent leaves a child, through the BINARY | 0 | `runReachesAnAgentThatLeftAChild` |
| `probe` — the agent refuses `session/new` | 1 | `probeReachesAnAgentThatRefusesTheSession` |
| `probe` — the bounded wait for a command list ends first | 0 | `probeReachesAnAgentThatReportsNoCommandList` |
| `probe` — the agent does not implement `session/close` | 0 | `probeReachesAnAgentWithNoSessionClose` |
| `probe` — the agent ends the moment it starts | 1 | `probeReachesAnAgentThatEndsAtOnce` |
| `doctor` SUBCOMMAND — every row passes | 0 | `doctorReachesAnAgentThatPassesEveryRow` |
| `doctor` SUBCOMMAND — a row reports an error | 1 | `doctorReachesAnAgentThatFailsARow` |
| the whole set, twice in a row | — | `theWholeSweepRunsTwiceInARow` |
| the spawn itself fails, and no agent is ever made | 1 | `aFailedSpawnLeavesNothingBehind` |

### Paths that do not exist

- **A `--cwd` that does not resolve.** Not reachable from any command line.
  `AgentSession.sessionWorkingDirectory(for:)` makes every `--cwd` value
  absolute against the process working directory with
  `URL(fileURLWithPath:relativeTo:).standardizedFileURL`, and
  `AbsolutePath.init?(rawValue:)` refuses only a string that does not start
  with `/`. So `SessionWorkingDirectoryError` cannot be thrown. Task
  ^x71mrtr holds the question.
- **A usage error AFTER a spawn.** There is none. `RunCommand` resolves the
  prompt BEFORE it starts the agent, and `SharedOptions.validate()` and
  `AgentInvocation.validate()` both run in the parser, so every §9 row-2 exit
  happens with no agent started at all. `RunCommandExitTests` and
  `TimeoutTests` already assert those rows.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-04 22:47)

> Scope: `review sha d08d44b~1..d08d44b` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 10 not reviewed (`.kanban/`, from `.reviewignore`).

The validator fleet returned zero findings. The rows below come from the
directed verification of the four judgement points, and each one lands on a
line this commit added.

- [x] `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/NoLeakedAgentTests.swift:39` `tests/assertion-cannot-fail` — the header states "`kill(pid, 0)` still reaches a ZOMBIE, so a pid that is gone is a pid that was reaped and not merely killed". The reading is taken AFTER `acp-client` has exited. When a parent exits, its unreaped children are reparented to `launchd` and reaped at once, so the pid is gone whether or not `acp-client` reaped it. Measured on this machine: while the parent still runs, an unreaped child is REACHABLE; after the parent exits, the same pid is GONE (ESRCH). The instrument is right for "still alive" and cannot fail for "was reaped" — the same defect the header raises against `waitpid`. Correct the header to claim only what the instrument measures, or move the reading to a moment when `acp-client` is still alive.
      **FIXED.** The header now opens "**This file claims no reap, and it cannot.**", states the `launchd` reparenting and the measurement, says `processExists(_:)` is sound only for "is anything STILL ALIVE", and names the seam that does carry the reap.
- [x] `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/NoLeakedAgentTests.swift:85` `tests/assertion-cannot-fail` — `runReachesAnAgentThatGoesAwayMidTurn` is documented as the zombie row: "a binary that killed without reaping would leave the pid in the table". It would not: the pid leaves the table when `acp-client` exits, whatever `acp-client` did. So the acceptance row "An agent that dies in the middle of a turn gives exit 1 and is reaped, not left as a zombie" is asserted by no test in this suite. Either assert the reap while the binary still runs, or state on the card that the reap is proven by `AgentProcess`'s own unit seam and not by this sweep.
      **FIXED.** The reap cannot be asserted while the binary runs: `AgentProcess` reaps on the EOF branch of its reader thread, microseconds before `acp-client` exits, and the only way to hold the binary open past the agent's death is a grandchild holding the stdout pipe — on which path a zombie is the CORRECT state until teardown. So the card takes the other option: the acceptance row and the Tests row above now say the reap is proven by `AgentProcessTests.killingAgentSurfacesDisconnectedState`, and the case doc of `runReachesAnAgentThatGoesAwayMidTurn` no longer claims it.
- [x] `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/NoLeakedAgentTests.swift:63` `tests/harness-hang` — the doc of `noLeakRunBound` states "a run that hangs fails as the hang it is". It does not, in the one failure this suite exists to detect. On the bound, `runAcpClient` sends `SIGKILL` to `acp-client` ALONE, and `AgentProcess.spawnChild` redirects only descriptors 0 and 1, so a surviving agent inherits and holds open the harness's stderr write end. `async let standardErrorData = readToEnd(...)` wraps the synchronous, non-cancellable `FileHandle.readToEnd()`, so the implicit await at scope exit never returns. A leaked agent WEDGES the test instead of failing it — which is what the implementer saw as "one test unreturned after 240 s", and what left wedged `swift-test` processes on an earlier review. Make the bound kill the agent's process group as well as the binary, or drain stderr with a cancellable read, so the guard reports a leak rather than hanging on it.
      **FIXED, by the second of the two ways.** The first is not open: `Process` puts `acp-client` in the TEST RUNNER's own process group, so a `killpg` there would kill the test runner. `runAcpClient` now drains both pipes through `PipeDrain`, which reads them as the bytes arrive and gives up `pipeDrainGrace` after the run ended; `readToEnd(_:)` and `drainedBytes(from:)` are gone. Proven by re-running the `killpg`→`kill` mutation: before the fix the suite printed nothing and `timeout` killed it at 180 s; after the fix it FAILS in 16.5 s with 3 named issues, "the process with pid 66357 outlived run, against an agent that leaves a child behind".
