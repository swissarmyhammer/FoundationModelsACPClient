---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rh7pqxp9dcpj96sbfzzrwz
  text: |
    ### decision — send `--cwd` as typed; the agent is the only judge

    A person decided this in discussion, from the protocol text at https://agentclientprotocol.com/protocol/v2/session-setup#creating-a-session. The client gives no opinion about `--cwd`. It does not resolve, does not normalise, and does not check.

    **Reasons**

    1. Only the agent can say if a directory exists and can be used. The agent can be on a different machine.
    2. ACP v2 has no field that tells the client the working directory of the agent. A relative `--cwd` is relative to the agent, and the client cannot learn what to resolve it against.
    3. The schema gives `cwd` the type `string` and states "Must be an absolute path" in prose only. The documentation says the same and names no validator. The agent validates and answers JSON-RPC invalid params (-32602). `FoundationModelsACPAgent` already has that check in `SessionSetup.validatedWorkingDirectory(path:)`.
    4. Today the wire package refuses a relative path at decode, before the agent can. That is a second validator on the wrong side of the wire. It goes. Card in `FoundationModelsACP`: "AbsolutePath: mirror the schema, and stop refusing relative paths at decode". Card in `FoundationModelsACPAgent`: "The agent is the only judge of cwd: validate session/list too, and name the field in the error".

    **Depends on**

    The `FoundationModelsACP` card, pushed and re-resolved in `Package.resolved`. This card cannot start before that. After it, `AbsolutePath(rawValue:)` is non-failable.

    **What to change here**

    - [x] `Sources/AcpClientCore/AgentSession.swift`: delete `sessionWorkingDirectory(for:)`. It resolves a relative path against the working directory of *this* process, which is the wrong base. This is the true defect.
    - [x] Delete the `standardizedFileURL` step. `..` resolves differently through a symbolic link, and the file system of the agent decides.
    - [x] Delete `SessionWorkingDirectoryError` and the `absolutePath(_:)` helper. Keep one error for the one true failure of this process: `FileManager.default.currentDirectoryPath` is empty because the working directory is deleted.
    - [x] Keep `cwd` in `Sources/AcpClientCore/SharedOptions.swift` as `String?`. `AgentSession` wraps it with `AbsolutePath(rawValue:)` and sends it as typed. With no `--cwd`, send the working directory of the client process.
    - [x] Sweep the sites that unwrap `AbsolutePath(rawValue:)`; they stop compiling. `Sources/AcpClientCore/AgentSession.swift` 1, `Tests/.../DecliningClientTests.swift` 2, `TerminalDisplayTests.swift` 1, `SessionStateTests.swift` 1, `RehydrationTests.swift` 1, `InProcessConnectionTests.swift` 1, `IntegrationTests/.../CLITestSupportTests.swift` 2, `AgentProcessTests.swift` 1.
    - [x] `cli-plan.md` §6.1: `--cwd` goes to the agent exactly as typed. The agent decides if it is usable. A relative value is the agent's to refuse, and the client reports that refusal as an agent error under the existing §9 row for a refused `session/new`. No new usage-error row.

    **Tests**

    - [x] `Tests/FoundationModelsACPClientTests/AgentSessionTests.swift`: `aRelativeCwdReachesNewSessionAsAnAbsolutePath` becomes `aRelativeCwdReachesNewSessionAsTyped`, and asserts `agent.lastWorkingDirectory?.rawValue == "Sources"`. Delete the `absoluteForm(of:)` helper.
    - [x] `anAbsoluteCwdReachesNewSessionUnchanged` and `anAbsentCwdUsesTheProcessWorkingDirectory` stay as they are.
    - [x] Integration: `acp-client run --cwd src` against the stub agent that refuses a relative cwd with -32602 exits with the §9 agent-error code and prints the agent's `data.field` and `data.reason` on stderr.
  timestamp: 2026-09-05T10:18:41.789719+00:00
- actor: claude-code
  id: 01m1rhrmn70gx5zyrftbb0mhvc
  text: |
    ### cross-package cards

    - `FoundationModelsACP` `01M1RHQ2WA85SQF9HTFV6NKAPX` — "AbsolutePath: mirror the schema, and stop refusing relative paths at decode". Lands first.
    - `FoundationModelsACPAgent` `01M1RHQ51PC25C3QM15JN3WPBF` — "The agent is the only judge of cwd: validate session/list too, and name the field in the error". Depends on the wire card.
    - This card depends on the wire card. `depends_on` cannot cross a board, so the order is recorded here in text.
  timestamp: 2026-09-05T10:27:56.711446+00:00
- actor: claude-code
  id: 01m1s0p5qjdyyb3wq32swp43zn
  text: |
    ### implement — research

    **Prerequisite.** `swift package update FoundationModelsACP` at the root and in `IntegrationTests` both answer "Everything is already up-to-date". Both `Package.resolved` files pin `3b0a4fdaab75c46a9dbdfdf929c84b456c8450c3`, which is `origin/main` and holds `f6e2b6e` as an ancestor. `.build/checkouts/FoundationModelsACP/Sources/FoundationModelsACP/Core/AbsolutePath.swift` has a non-failable `public init(rawValue: String)`. `.gitignore` line 8 ignores `Package.resolved`, so neither file is in `HEAD` and neither can be part of a commit. `git status` shows no change to them.

    **The build is broken today.** `swift build --build-tests` at the root stops at `Sources/AcpClientCore/AgentSession.swift`: `guard let absolute = AbsolutePath(rawValue: path)` — "initializer for conditional binding must have Optional type". The test sites that unwrap `AbsolutePath(rawValue:)` stop compiling after that one.

    **Callers of `AgentSession.init`:** `RunCommand.runTurn`, `ProbeCommand`, and `AgentCommandDoctor` (opens no session). A defaulted parameter changes none of them.

    **Error text on stderr.** `RunCommand` and `ProbeCommand` write `String(describing: error)`. `RequestError` is `ACPError`, a generated struct with no `CustomStringConvertible`, and `RequestError(wire:)` keeps `data`. The default description of the struct carries the `data` object, so `field` and `reason` reach stderr.

    **Stub agents.** `StubAgents.swift` has `makeNewSessionRefusingAgent` (internal error, no `data`) and `requestError(id:code:message:)` with no `data`. The wire codec writes `.sortedKeys` and `.withoutEscapingSlashes`, so a shell stub can match `"cwd":"/` to tell an absolute path from a relative one. The new stub judges the path: it opens a session for an absolute `cwd` and refuses any other `cwd` with `-32602` and `data: {"field":"cwd","reason":"must be absolute"}`. That is what makes the integration test red before the change: the old client made `src` absolute, the stub then opened a session, and the run exited 0.

    **Plan.** `cli-plan.md` §6.1 says "A relative value is made absolute against the process working directory" and "§16 holds the open question". §16 holds the bullet "What `--cwd` owes", which says "The answer needs a person". A person answered, so that bullet goes with the decision.

    **Rules read.** `dump validators` for `AgentSession.swift` and `cli-plan.md`: 60 rules, read whole.
  timestamp: 2026-09-05T14:48:44.530971+00:00
- actor: claude-code
  id: 01m1s0xnyp0pmp9h3d6h1jj67p
  text: |
    ### implement — red

    The build was broken by the dependency, so a scaffold in `absolutePath(_:)` restored the OLD behaviour (`guard path.hasPrefix("/")`) for the red runs only. The scaffold goes in the green step.

    `swift test --filter 'aRelativeCwdReachesNewSessionAsTyped|sectionSixPointOneStatesThatCwdGoesToTheAgentAsTyped'`: 2 tests, 3 issues, exit 1.
    - `aRelativeCwdReachesNewSessionAsTyped`: `agent.lastWorkingDirectory?.rawValue` was `/Users/wballard/github/swissarmyhammer/FoundationModelsACPClient/Sources`, expected `Sources`.
    - `sectionSixPointOneStatesThatCwdGoesToTheAgentAsTyped`: no §6.1 sentence names `--cwd` with "as typed"; the sentence "A relative value is made absolute against the process working directory, and the result goes to the agent as it stands" holds the resolution words.

    `swift test --package-path IntegrationTests --filter 'aRelativeCwdReachesTheAgentAsTypedAndItsRefusalIsReported|anAbsoluteCwdReachesTheJudgingAgentAndTheSessionOpens'`: 2 tests, 4 issues, exit 1.
    - `aRelativeCwdReachesTheAgentAsTypedAndItsRefusalIsReported`: exit code 0, expected 1; stdout held the 26-byte answer; stderr was empty, so it named neither `cwd` nor `must be absolute`. The client made `src` absolute, the judging stub saw `"cwd":"/...`, and it opened the session.
    - `anAbsoluteCwdReachesTheJudgingAgentAndTheSessionOpens` passed. It is the control: the same stub opens a session for an absolute path, so the refusal above comes from the path and not from a stub that refuses every `session/new`.
  timestamp: 2026-09-05T14:52:50.518949+00:00
- actor: claude-code
  id: 01m1s15zff9a1fnhvez7wm9906
  text: |
    ### implement — changed

    - evidence: `swift test` (root): 227 tests in 20 suites passed, exit 0. `swift test --package-path IntegrationTests`: 89 tests in 12 suites passed, exit 0. The whole output holds no `warning:`, no skipped test and no failure.
    - evidence: `FoundationModelsACP` resolved at `3b0a4fdaab75c46a9dbdfdf929c84b456c8450c3` in both `Package.resolved` files (after `f6e2b6e`). `.gitignore` ignores `Package.resolved`, so neither file can be part of the commit; `git status` shows no change to them.
    - evidence: red then green, on the card in the two comments above. Cycle 1: `aRelativeCwdReachesNewSessionAsTyped`, the §6.1 plan guard `sectionSixPointOneStatesThatCwdGoesToTheAgentAsTyped`, and the integration test `aRelativeCwdReachesTheAgentAsTypedAndItsRefusalIsReported` were red against the scaffolded old behaviour, then green after the change. Cycle 2: `anEmptyProcessWorkingDirectoryIsReportedAndNoSessionOpens` was red (no `processWorkingDirectory` parameter, no `ProcessWorkingDirectoryError`), then green. `anAbsoluteCwdReachesTheJudgingAgentAndTheSessionOpens` is the control of the integration test and passed on both runs.
    - files, 17: `Sources/AcpClientCore/AgentSession.swift` (delete `sessionWorkingDirectory(for:)`, the `standardizedFileURL` step, `absolutePath(_:)` and `SessionWorkingDirectoryError`; send `--cwd` as typed; add the injected `processWorkingDirectory` reader, `workingDirectoryToSend()` and `ProcessWorkingDirectoryError` for an empty process working directory; header and doc comments), `Sources/AcpClientCore/ProbeCommand.swift`, `Sources/AcpClientCore/RunCommand.swift`, `Sources/AcpClientCore/TurnRunner.swift` (`- Throws:` doc sweep), `cli-plan.md` (§6.1 rewritten; the decided "What `--cwd` owes" bullet removed from §16 because §6.1 no longer points at it; no section renumbered, no §9 row), `README.md` (the `!` on `AbsolutePath(rawValue:)`), `Tests/FoundationModelsACPClientTests/AgentSessionTests.swift` (test renamed and rewritten, `absoluteForm(of:)` deleted, harness reader, empty-directory test), `Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift` (guard for the §6.1 as-typed sentence and against a "made absolute" sentence), `Tests/FoundationModelsACPClientTests/DecliningClientTests.swift`, `InProcessConnectionTests.swift`, `RehydrationTests.swift`, `SessionStateTests.swift`, `TerminalDisplayTests.swift`, `IntegrationTests/.../AgentProcessTests.swift`, `IntegrationTests/.../CLITestSupportTests.swift` (unwrap sweep), `IntegrationTests/.../Support/StubAgents.swift` (`StubAgentNewSessionAnswer` with `judgesWorkingDirectory`, `requestError(id:code:message:data:)`, `makeWorkingDirectoryJudgingAgent(pidFile:)`), `IntegrationTests/.../RunCommandExitTests.swift` (the two `--cwd` tests).
    - not done by decision: the description's Answer 1 box stays open. Answer 2 was decided, and the two answers exclude each other.
    - next: `/review`. The card stays in `doing`.
  timestamp: 2026-09-05T14:57:22.415533+00:00
- actor: claude-code
  id: 01m1s191jcjdhxq999k87hdjvd
  text: |
    ### test — green

    - evidence: `swift test` (root) — 227 tests in 20 suites passed, exit 0. No warning line, no skipped test, no failure.
    - evidence: `swift test --package-path IntegrationTests` — 89 tests in 12 suites passed, exit 0. No warning line, no skipped test, no failure.
    - evidence: `grep code` for `.disabled(`, `XCTSkip`, `.skip(` — no match. No test is skipped or disabled.
    - evidence: `git status --porcelain` after both runs shows only the files the implement step already changed. No probe file or process was left behind.
    - next: `/review`.
  timestamp: 2026-09-05T14:59:02.860093+00:00
position_column: doing
position_ordinal: '80'
title: 'Send --cwd to the agent as typed: delete the client-side resolution and the dead error'
---
## What

`AgentSession.SessionWorkingDirectoryError` is dead on every command line.

`AgentSession.sessionWorkingDirectory(for:)` builds the session directory as
`URL(fileURLWithPath: requested, relativeTo: processDirectory).standardizedFileURL`,
which is always an absolute path, and `AbsolutePath.init?(rawValue:)` refuses
only a string that does not start with `/`. So `absolutePath(_:)` never
returns `nil` for any `--cwd` value a person can type, and the error type it
throws has no reachable caller.

Found while sweeping every exit path of §11 (task ^f1fz3bv). The sweep looked
for the "--cwd does not resolve" exit path and there is none to sweep.

## The question this task answers

`cli-plan.md` §6.1 says `--cwd <path>` is "the working directory of the
session". A path that does not EXIST is passed to the agent unchecked today,
and the agent is left to fail on it. Two answers are open:

1. **The check is what is missing.** `--cwd` should reject a path that names
   no directory, with the usage row of §9. The error type then has a caller,
   and the message names the path the person typed.
2. **The check is not owed.** The session directory belongs to the AGENT, and
   an agent may hold a workspace this process cannot see. Then the error type
   is dead code and it goes, and §6.1 says so.

A person decides which. Do not guess.

## Acceptance Criteria

- [x] The decision is recorded in `cli-plan.md` §6.1.
- [ ] Answer 1: `--cwd` is checked, the check has a unit test, and the error
      carries the path.
- [x] Answer 2: `SessionWorkingDirectoryError` and `absolutePath(_:)` are
      deleted, and `openSession()` no longer says it throws them.
- [x] Either way, no unreachable error type is left behind.

## Files

- `Sources/AcpClientCore/AgentSession.swift`
- `cli-plan.md` §6.1
