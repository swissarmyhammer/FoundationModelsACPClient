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
depends_on:
- 01M1MPFEP97Z6J3R0MRC6XXKAJ
- 01M1MPARCGY1FHKNED47MDBWG8
- 01M1MPB4MKQH0Z50EH2DDJHW3G
- 01M1MPC2YVFK0A9NX4T9H4M0EV
- 01M1MPECJSM165NAWX5F3NKX9A
position_column: doing
position_ordinal: '80'
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