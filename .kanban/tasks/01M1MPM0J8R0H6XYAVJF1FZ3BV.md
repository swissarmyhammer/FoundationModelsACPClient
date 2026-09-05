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
depends_on:
- 01M1MPG0WT31XJVP37C3CAT35C
- 01M1MPJRCZKG9CEZ7N5TDX6EDK
- 01M1MPKCCB56CA910R6JA5XSFA
position_column: doing
position_ordinal: '80'
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
- [x] An agent that dies in the middle of a turn gives exit 1 and is reaped,
      not left as a zombie.
- [x] The suite fails loudly, naming the pid and the exit path, when a process
      is still alive.

## Tests

- [x] `NoLeakedAgentTests.swift`, one test per acceptance row above.
- [x] One test asserts the zombie case directly: after the binary exits,
      `waitpid` for the agent pid reports no such process, so the pid was
      reaped and not merely killed.
      **The instrument changed, and the row stands.** `waitpid` answers
      `ECHILD` for every pid that is not a child of the caller. The stub agent
      is a child of `acp-client` and a GRANDCHILD of the test, so `waitpid`
      from the test answers the same whether the agent is alive or dead: such
      an assertion cannot fail. `processExists(_:)` is the instrument that
      bites, because `kill(pid, 0)` still reaches a ZOMBIE, so a pid that is
      gone is a pid that was reaped. The zombie claim is carried by
      `runReachesAnAgentThatGoesAwayMidTurn` (the agent dies while the binary
      still runs, so the binary is what owes the `waitpid`) beside
      `runReachesAnAgentThatLeftAChild`. The file header states the whole
      argument.
- [x] One test runs the whole set twice in a row and asserts the second run is
      unaffected by the first, which catches a leaked descriptor.
- [x] Run `swift test --package-path IntegrationTests`. Every assertion
      passes. 75 tests in 12 suites, 19.1 s. The root `swift test` also passes:
      215 tests in 17 suites.

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

### Added by this card, in `NoLeakedAgentTests.swift`

| The path | Exit code | Row |
|---|---|---|
| `run` — the agent goes away in the middle of the turn (the zombie row) | 1 | `runReachesAnAgentThatGoesAwayMidTurn` |
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
