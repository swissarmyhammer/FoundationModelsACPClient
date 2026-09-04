---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1pwkwdkrjqqe1bz2g4gq0x2
  text: |-
    Research done. What the wiring rests on:

    - `AcpClient.main()` already gives the exit path: an error that ArgumentParser calls a validation failure gets `fullMessage(for:)` on stderr and exit 2; every other error goes to `exit(withError:)`. ArgumentParser's `MessageInfo` maps an `ExitCode` error to an EMPTY message and that exact code, and a `ValidationError` thrown from `run()` to `.validation(message:usage:help:)`, which carries the usage text and `validationFailure`. So:
      - `PromptSourceError.noPromptAndStdinIsATerminal` becomes a `ValidationError`, which gives the §7 row 3 result (usage text on stderr, exit 2, stdout untouched) with no new code.
      - Every other outcome is thrown as `ExitCode`, which prints nothing and carries the number. A new `AcpClientExitCode.parserExitCode` in `ExitCode.swift` is the one place that spells it, so the `ExitCodeTests` literal scan stays green.
    - `AgentSession` and `TurnRunner` are `@MainActor`; `RunCommand.run()` is not. The turn goes in a `@MainActor` static helper that takes only Sendable values (`any ACPTransport` is `Sendable`).
    - `defer` cannot `await`, so `AgentProcess.shutdown()` goes in a `defer` (idempotent, reaps on every path) and the async `AgentSession.teardown()` runs on the single path after a `Result` holds the outcome.
    - `AgentInvocation.agentCommand` is a `[String]` whose emptiness `validate()` already rejects. The split into executable and arguments needs the same failure in a second place, so the message moves to one static and both members read it.

    Integration-suite gap found: `runAcpClient` gives the run either a regular file or `/dev/null` on stdin, so no test can make stdin a TERMINAL, which acceptance row 5 needs. The fix is a `posix_openpt`/`grantpt`/`unlockpt`/`ptsname` pseudo-terminal handed to the child as fd 0, and `standardInput` becomes a three-case value (end of file, bytes, terminal) rather than a `Data?`.

    To prove the §7 rows through the real binary the stub agent has to record what it received, because a `/bin/sh` agent cannot echo a JSON prompt back. `StubAgents` grows an optional transcript file (every request line appended) and an optional pid file (`$$`, for the "no agent outlives the run" row).
  timestamp: 2026-09-04T18:59:06.291044+00:00
- actor: claude-code
  id: 01m1px9y43rz4s8xfb40hm54c0
  text: |-
    Implementation landed, TDD order kept: the seven new integration tests were written and watched fail first (21 issues, every acceptance row red because `run` still threw `SubcommandNotImplementedError`), then the wiring made them pass.

    What the wiring looks like, and why:

    - `RunCommand.run()` resolves the prompt BEFORE it starts the agent. The §7 row that has no prompt to read is a usage error, and a usage error must not leave a started agent behind, so that row now spawns nothing at all.
    - `PromptSourceError.noPromptAndStdinIsATerminal` becomes a `ValidationError`. ArgumentParser reads that as `.validation(message:usage:help:)`, and `AcpClient.main()` already writes `fullMessage(for:)` to stderr and exits 2 for it, so §7 row 3 needed no new code.
    - Every other outcome leaves as the parser's `ExitCode`, which ArgumentParser prints as an EMPTY message. A success returns normally instead, so the process ends through its own exit path and every `atexit` sweep still runs. The one place that turns a §9 row into a number is the new `AcpClientExitCode.parserExitCode` in `ExitCode.swift`, so the literal scan of `ExitCodeTests` stays green.
    - `AgentProcess.shutdown()` is a `defer` around the whole turn. `AgentSession.teardown()` cannot be, because `defer` cannot `await`, so the outcome is held in a `Result` and the single teardown runs on the one path that follows.
    - `AgentInvocation` gained `command() -> AgentCommand` and a shared `missingAgentCommand`, because the split into executable and arguments needs the same failure `validate()` already reports and the message must not be written twice.

    Two things worth knowing for the next agent:

    1. **A test process cannot make its own standard input a terminal.** The acceptance row for "no prompt with stdin a terminal" was unreachable through the old `runAcpClient(_:standardInput: Data?)`. `standardInput` is now a `CLIStandardInput` value with three cases, and `.terminal` opens a `posix_openpt`/`grantpt`/`unlockpt`/`ptsname` pseudo-terminal and hands the child its slave end. The MASTER end must stay open for the whole run — closing it hangs the slave up, and a hung-up slave is no longer a terminal.
    2. **A `/bin/sh` agent cannot answer WITH what it was sent**, so the §7 prompt rows could not be proved by reading stdout. `StubAgents` grew an optional transcript file: the agent appends every raw request line it reads, and the test asserts the prompt text stands in it. The same mechanism carries the pid (`$$`, written before the agent answers anything), which is what lets a test outside the run probe `kill(pid, 0)` after each exit.

    On the StubAgents item of the card: after this change `StubAgents` produces all three of the asked-for agents. The `refusal` and the `cancelled` agents come from `makeWellBehavedAgent(stopReason:)`, which already took the reason as a parameter and which the new `TurnEnding` case list drives; the third needed new code and is the new `makeIdleWithoutStopReasonAgent(answer:pidFile:)`, whose `idleState` omits the `stopReason` member rather than writing `null`, because a real agent that reports no reason omits it. Two one-line named wrappers for the first two were considered and left out: they would forward to the parameterized builder and add nothing a reader or a test could use.

    A swift-testing constraint found on the way: a `@Test` method whose parameter type is file-private must itself be `private`, or the build fails with "method must be declared fileprivate because its parameter uses a private type". Discovery is unaffected — swift-testing finds a test by its `@Test` attribute, never by its visibility.
  timestamp: 2026-09-04T19:11:08.931559+00:00
- actor: claude-code
  id: 01m1pxa4pdykdhcn212r9v7ymm
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/acp-client/RunCommand.swift, Sources/acp-client/ExitCode.swift, Sources/acp-client/AgentInvocation.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/RunCommandExitTests.swift (new), IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/CLITestSupport.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/TemporaryFiles.swift. `timeout 420 swift test` — 180 tests in 12 suites passed, 0 failures, 0 warnings. `timeout 600 swift test --package-path IntegrationTests` — 17 tests in 4 suites passed, 0 failures, 0 warnings. TDD order kept: the new suite was watched fail first with 21 issues over all 7 tests. Every acceptance row and every Tests row of the card is checked. No stray test or stub-agent process, and no leftover temporary file, after the runs.
    - next: /review
  timestamp: 2026-09-04T19:11:15.661803+00:00
- actor: claude-code
  id: 01m1pxp29ht2qsf2bk9cgbzvh1
  text: |
    ### review — findings
    - scope: `review sha 93fc57e~1..93fc57e`, the diffs only
    - counts: 2 findings, 2 confirmed, 0 refuted, 7 files attempted
    - evidence: IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/RunCommandExitTests.swift:293, RunCommandExitTests.swift:309

    Judgement of the three points the implementer sent:

    1. The teardown holds on every path. `run()` resolves the prompt and the
       command BEFORE `runTurn`, so a throw from either one starts no process.
       In `runTurn`, the resolver and the `AgentProcess` initializer both throw
       before the `defer` is set, and there is no process to leave alive at that
       time. After the initializer gives a process, the `defer` is set with no
       await between the two, so every later path reaps. `AgentProcess.shutdown()`
       goes to `terminateCurrent()`, which does `killpg(SIGKILL)` and then a
       blocking `waitpid`, so the pid is reaped before `shutdown()` returns.
       In `driveTurn`, `await AgentSession(...)` is not a `try`, so the
       initializer cannot throw. The `do` block puts every error into the
       `Result`, and `await session.teardown()` is not a `try` either. No path
       leaves the session open. The point is correct.

    2. The exit is 2 and not 64. `@main` is on `AcpClient`, and `AcpClient`
       declares its own `static func main() async`, which hides the default of
       `AsyncParsableCommand`. That `main()` catches the `ValidationError` the
       `run()` body throws, reads `exitCode(for:)` as `.validationFailure`,
       writes `fullMessage(for:)` to stderr, and exits with
       `processExitCode(for:)`, which maps `.validationFailure` to
       `AcpClientExitCode.usage`, that is 2. stdout stays empty. The integration
       test `noPromptWithATerminalIsAUsageError` asserts the same three things.
       The point is correct.

    3. The acceptance row is met. The row asks for stub agents that end with
       `refusal`, with `cancelled`, and with an `idle` that carries no
       `stopReason`. `makeWellBehavedAgent(stopReason:)` writes a different
       script for each stop reason, so the `refusal` agent and the `cancelled`
       agent are real, separate agents on the wire. `idleState(nil)` leaves the
       `stopReason` member OUT rather than writing `null`, which is the case the
       schema needs. All three endings run through the exit-code tests, and all
       four endings run through the pid test. A parameter is a correct way to
       give the two stop-reason agents; three copied scripts would give no more
       proof. The point is correct.

    - next: correct the two access-control findings. Make `TurnEnding` and
      `PromptRow` internal, then remove `private` from
      `noAgentProcessOutlivesTheRun` and `eachPromptRowDeliversItsPrompt` and
      remove the comment that explains the `private`. The two types are types,
      not properties or functions, so the rule does not ask them to stay private.
  timestamp: 2026-09-04T19:17:46.417203+00:00
- actor: claude-code
  id: 01m1pxpvps508ays15d87gey5j
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 files; RunCommand now resolves the prompt and the command, starts the AgentProcess, builds the AgentSession, runs the TurnRunner into stdout, and exits through AcpClientExitCode
    - test: green — root 180 passed in 12 suites, integration 17 passed in 4 suites, 0 failures and 0 warnings on both
    - commit: 93fc57e feat(acp-client): wire RunCommand to spawn the agent and run the turn
    - review: findings — IntegrationTests/.../RunCommandExitTests.swift:293 and :309, both `code-hygiene/idioms-swift` testSuiteAccessControl

    The review confirmed the three points the implementer raised, so none of them is open work:
    - No path leaves the agent or the session alive. The prompt and the command resolve before any process starts; `AgentProcess.shutdown()` does `killpg` then a blocking `waitpid`, so the pid is reaped before it returns; the `do` block routes every error into the `Result` and one `await session.teardown()` runs after it.
    - `noPromptAndStdinIsATerminal` reaches exit 2, not 64. `AcpClient` declares its own `main()`, which maps `.validationFailure` through `processExitCode(for:)` to `AcpClientExitCode.usage`.
    - The stub-agent acceptance row is met. `makeWellBehavedAgent(stopReason:)` writes a different script per stop reason, so `refusal` and `cancelled` are distinct agents on the wire, and `idleState(nil)` omits the member instead of writing `null`.
  timestamp: 2026-09-04T19:18:12.441569+00:00
- actor: claude-code
  id: 01m1pxv2mxpa25e6t3wp5vm4xv
  text: |-
    Both `testSuiteAccessControl` findings are corrected, and the cause is removed from the WHOLE file and not only from the two reported lines.

    What the rule asks, word for word: "Test methods should have the configured access control (default internal), and other properties / functions in a test suite should be private."

    The block that held the cause:

    - `TurnEnding` and `PromptRow` were `private` at file scope. Each is the parameter type of one `@Test` method, and Swift lets no method be more visible than its parameters, so both methods had to be `private` as well. The rule reads a `private` `@Test` method as a finding.
    - The rule speaks of PROPERTIES and FUNCTIONS in a test suite. `TurnEnding` and `PromptRow` are neither: they are types, and they stand at file scope and not in the suite. So nothing holds them at `private`, and making them internal releases the two methods.

    The change:

    - `TurnEnding` and `PromptRow` are internal.
    - `noAgentProcessOutlivesTheRun(ending:)` and `eachPromptRowDeliversItsPrompt(row:)` are internal, in the same way as the five other `@Test` methods.
    - The four-line comment that explained the old `private` is removed. It described a constraint that no longer stands.

    The sweep of the rest of the file, so no second finding waits behind these two:

    - Every one of the seven `@Test` methods in `RunCommandExitTests` is now internal.
    - Every property in the suite stays `private`: `prompt`, `answer`, `pidFileNamePrefix`, `transcriptFileNamePrefix`.
    - Every function in the suite stays `private`: `runArguments(prompt:script:)` and `recordedPid(in:)`.
    - The suite holds no other declaration.
    - `runSuiteTimeLimitMinutes`, `SectionNineExitCode` and `standardInputPromptArgument` stay `private`. They stand at file scope, outside the suite, so the rule does not reach them, and no signature in the file needs them to be more visible.

    Checked for a name collision before making the two types internal: `TurnEnding` and `PromptRow` are named in this file only, in the whole repository.

    `swift build --package-path IntegrationTests --build-tests` reports zero warnings and zero errors, and no test process is left after the runs.
  timestamp: 2026-09-04T19:20:30.621190+00:00
- actor: claude-code
  id: 01m1pxv7df8kky99wbgkg7mx6h
  text: |-
    ### implement — changed
    - evidence: 1 file — IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/RunCommandExitTests.swift. `timeout 420 swift test` — 180 tests in 12 suites passed, 0 failures. `timeout 600 swift test --package-path IntegrationTests` — 17 tests in 4 suites passed, 0 failures. `swift build --package-path IntegrationTests --build-tests` — 0 warnings, 0 errors. Both `code-hygiene/idioms-swift` testSuiteAccessControl findings are checked in the description.
    - next: /review
  timestamp: 2026-09-04T19:20:35.503702+00:00
- actor: claude-code
  id: 01m1py07z7yx8gaqfe2cn3v7va
  text: |
    ### review — clean
    - evidence: `review sha 3802458~1..3802458` — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. Both prior findings (RunCommandExitTests.swift:293 and :309, `code-hygiene/idioms-swift` testSuiteAccessControl) are resolved and checked: `TurnEnding` and `PromptRow` are internal, both `@Test` methods dropped `private`, and the comment that explained the old access level is gone.
    - next: none — the task moved to `done`.
  timestamp: 2026-09-04T19:23:19.911701+00:00
- actor: claude-code
  id: 01m1py0nxyyfwy5cvnm5rnanvv
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file; both testSuiteAccessControl findings removed at the cause. `TurnEnding` and `PromptRow` were `private` at file scope, and Swift lets no method be wider than its parameter types, so the two `@Test` methods that take them were held at `private` too. Making the two types internal releases both methods. The sweep of the rest of the suite found no second occurrence.
    - test: green — root 180 passed in 12 suites, integration 17 passed in 4 suites, 0 failures; the integration test build reports 0 warnings
    - commit: 3802458 fix(tests): make TurnEnding and PromptRow internal in RunCommandExitTests
    - review: clean — zero new findings, both prior items confirmed in the diff, task moved to done
  timestamp: 2026-09-04T19:23:34.206311+00:00
depends_on:
- 01M1MPFEP97Z6J3R0MRC6XXKAJ
- 01M1MPARCGY1FHKNED47MDBWG8
- 01M1MPB4MKQH0Z50EH2DDJHW3G
- 01M1MPC2YVFK0A9NX4T9H4M0EV
- 01M1MPECJSM165NAWX5F3NKX9A
position_column: done
position_ordinal: '9880'
title: 'Wire RunCommand: spawn the agent, run the turn, and exit with the right code'
---
## What

Join the pieces into the default subcommand. `TurnRunner` holds no process
handling by design, so this task owns the `AgentProcess` and the exit.

Edit `Sources/acp-client/RunCommand.swift`:

- Resolve the agent command through `AgentCommandResolver`, so a bare name and
  a relative path both reach `AgentProcess` as the absolute path it demands.
- Resolve the prompt through `PromptSource`. The
  `noPromptAndStdinIsATerminal` failure becomes the usage text on stderr and
  exit 2, with stdout untouched.
- Construct `AgentProcess`, build an `AgentSession` over its transport, and
  run a `TurnRunner` with `answerSink` pointed at stdout.
- Exit through `AcpClientExitCode`: `forStopReason(_:)` for a
  `.stopped(reason)` outcome, `success` for `.idleWithNoReason`, and
  `forError(_:)` for a spawn, protocol or I/O failure.
- **Tear the agent down on every path**, in a `defer`, so success, failure and
  a thrown error all reap it. `AgentProcess.shutdown()` is idempotent.

No file in `Sources/acp-client/` outside `ExitCode.swift` may hold a bare
numeric exit literal; this is the task that makes that true, and
`ExitCodeTests` asserts it.

## Acceptance Criteria

- [x] `acp-client run "hi" -- <wellBehavedAgent>` writes the answer to stdout
      and exits 0.
- [x] A `refusal` stop reason exits 3, and a `cancelled` one exits 4.
- [x] An `idle` with no stop reason exits 0.
- [x] A command that is not on `PATH` exits 1 with an explanatory stderr line
      and an empty stdout.
- [x] No prompt with stdin a terminal exits 2, with an empty stdout.
- [x] The agent pid is gone after every one of those exits.

## Tests

- [x] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/RunCommandExitTests.swift`,
      one test per acceptance row above, through `runAcpClient(_:)`.
- [x] Extend `StubAgents` with agents that end their turn with `refusal`,
      with `cancelled`, and with an `idle` that carries no `stopReason`.
- [x] One test writes the agent pid to a pid file, waits for each exit, and
      asserts `kill(pid, 0)` reports the process is gone.
- [x] One test asserts the §7 prompt rows through the real binary: an
      argument, a piped stdin, and `-`.
- [x] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-04 14:12)

> Scope: `review sha 93fc57e~1..93fc57e` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/RunCommandExitTests.swift:293` `code-hygiene/idioms-swift` — testSuiteAccessControl: Test methods should have the configured access control (default internal), and other properties / functions in a test suite should be private.
- [x] `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/RunCommandExitTests.swift:309` `code-hygiene/idioms-swift` — testSuiteAccessControl: Test methods should have the configured access control (default internal), and other properties / functions in a test suite should be private.
