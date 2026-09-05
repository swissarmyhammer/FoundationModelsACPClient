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

    - [ ] `Sources/AcpClientCore/AgentSession.swift`: delete `sessionWorkingDirectory(for:)`. It resolves a relative path against the working directory of *this* process, which is the wrong base. This is the true defect.
    - [ ] Delete the `standardizedFileURL` step. `..` resolves differently through a symbolic link, and the file system of the agent decides.
    - [ ] Delete `SessionWorkingDirectoryError` and the `absolutePath(_:)` helper. Keep one error for the one true failure of this process: `FileManager.default.currentDirectoryPath` is empty because the working directory is deleted.
    - [ ] Keep `cwd` in `Sources/AcpClientCore/SharedOptions.swift` as `String?`. `AgentSession` wraps it with `AbsolutePath(rawValue:)` and sends it as typed. With no `--cwd`, send the working directory of the client process.
    - [ ] Sweep the sites that unwrap `AbsolutePath(rawValue:)`; they stop compiling. `Sources/AcpClientCore/AgentSession.swift` 1, `Tests/.../DecliningClientTests.swift` 2, `TerminalDisplayTests.swift` 1, `SessionStateTests.swift` 1, `RehydrationTests.swift` 1, `InProcessConnectionTests.swift` 1, `IntegrationTests/.../CLITestSupportTests.swift` 2, `AgentProcessTests.swift` 1.
    - [ ] `cli-plan.md` §6.1: `--cwd` goes to the agent exactly as typed. The agent decides if it is usable. A relative value is the agent's to refuse, and the client reports that refusal as an agent error under the existing §9 row for a refused `session/new`. No new usage-error row.

    **Tests**

    - [ ] `Tests/FoundationModelsACPClientTests/AgentSessionTests.swift`: `aRelativeCwdReachesNewSessionAsAnAbsolutePath` becomes `aRelativeCwdReachesNewSessionAsTyped`, and asserts `agent.lastWorkingDirectory?.rawValue == "Sources"`. Delete the `absoluteForm(of:)` helper.
    - [ ] `anAbsoluteCwdReachesNewSessionUnchanged` and `anAbsentCwdUsesTheProcessWorkingDirectory` stay as they are.
    - [ ] Integration: `acp-client run --cwd src` against the stub agent that refuses a relative cwd with -32602 exits with the §9 agent-error code and prints the agent's `data.field` and `data.reason` on stderr.
  timestamp: 2026-09-05T10:18:41.789719+00:00
- actor: claude-code
  id: 01m1rhrmn70gx5zyrftbb0mhvc
  text: |
    ### cross-package cards

    - `FoundationModelsACP` `01M1RHQ2WA85SQF9HTFV6NKAPX` — "AbsolutePath: mirror the schema, and stop refusing relative paths at decode". Lands first.
    - `FoundationModelsACPAgent` `01M1RHQ51PC25C3QM15JN3WPBF` — "The agent is the only judge of cwd: validate session/list too, and name the field in the error". Depends on the wire card.
    - This card depends on the wire card. `depends_on` cannot cross a board, so the order is recorded here in text.
  timestamp: 2026-09-05T10:27:56.711446+00:00
position_column: todo
position_ordinal: 9c80
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

- [ ] The decision is recorded in `cli-plan.md` §6.1.
- [ ] Answer 1: `--cwd` is checked, the check has a unit test, and the error
      carries the path.
- [ ] Answer 2: `SessionWorkingDirectoryError` and `absolutePath(_:)` are
      deleted, and `openSession()` no longer says it throws them.
- [ ] Either way, no unreachable error type is left behind.

## Files

- `Sources/AcpClientCore/AgentSession.swift`
- `cli-plan.md` §6.1
