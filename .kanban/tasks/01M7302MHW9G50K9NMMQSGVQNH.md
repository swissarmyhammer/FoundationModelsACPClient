---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7353806n1dqmnvznhs3chzh
  text: |-
    Research (implement):
    - Each SessionModel comes from ConnectionModel.makeSessionModel (root, resume and sub-agent child through makeSubscribedSessionModel). Thus the session states come from the `openedExtensions` of the connection in that one place.
    - `MCPServerListRequest` is internal today. The public protocol hook `didStartSession(state:mcpServers:)` needs it public. Plan: make it public (NewSessionRequest and ResumeSessionRequest already conform).
    - ReplayRollback is made only for a resume with history (`replayFrom != nil`, in beginReplay). Rule chosen from the card: a replay with history makes new session states (makeSessionState) in beginReplay; a failed replay gives the earlier state objects back through ReplayRollback. A resume with no history keeps the states (as it keeps the transcript); didStartSession then runs on the kept states. The close keeps the states.
    - The hook goes first in engineChange(folding:). The coalescer flushes before each non-chunk update, so the arrival order holds with no other change.
    - Context session lookup: gate on `connectionGeneration` (connect adds 1 before the extensions open; a close adds 1), so a handler of an earlier connection finds no session of a later one. Lookup = open sessions, then child sessions.
    - Preview: add `extensions:` to SessionModel.preview; a `.update(...)` transcript item then goes through the extension, and a host can set sample data through extensionState(_:).
  timestamp: 2026-11-10T16:36:40.582735+00:00
- actor: claude-code
  id: 01m735sr59c46g69f7pxb325t5
  text: |-
    Implementation landed (TDD: 20 new tests in ClientModelExtensionSessionTests failed to compile first, then passed).
    - New file Model/OpenedSessionExtensions.swift: OpenedSessionExtension (type-erased state + apply + didStartSession) and SessionExtensions (value type; take(_:) stops at the first true; remade() makes new states).
    - MCPServerListRequest is now public (the public hook needs it). Its doc no longer links the internal removingUnadvertisedMCPServers.
    - SessionModel.preview gained `extensions:`. Two DocC links to the old preview signature (PreviewTranscriptItem.swift, PreviewSessionRequestSender.swift) were updated; docc convert shows no warning for the changed symbols.
    - The misplaced doc comment of resetTranscript() (it stood above ReplayRollback) moved to resetTranscript(), with the extension-state rule.
    - Open point for the next task (^-next, the move of _mcp_server_status): a resume with NO history keeps the extension state, and runReplay gives back `mcpServers` on a refused request outside ReplayRollback. An extension that holds the MCP server list will need the same give-back for a refused resume with no history.
    - The "A session/update send failed" warnings in `swift test --package-path IntegrationTests` also appear at HEAD with the changes stashed: they are not from this change.
  timestamp: 2026-11-10T16:48:58.025342+00:00
- actor: claude-code
  id: 01m735svfrvyvf17wr9cz437s3
  text: |-
    ### implement — changed
    - evidence: swift build (only the allowed mlx metal warning); swift test 854 tests in 71 suites passed; swift test --package-path IntegrationTests 23 tests in 5 suites passed; filter ClientModelExtension|SessionModelMCPServerStatusTests|SessionModelMailPauseTests 70 tests passed. Files: Model/ClientModelExtension.swift, Model/OpenedSessionExtensions.swift (new), Model/OpenedExtensions.swift, Model/ConnectionModel.swift, Model/ConnectionModel+Sessions.swift, Model/SessionModel.swift, Model/SessionModel+Stream.swift, Preview/SessionModel+Preview.swift, Preview/PreviewTranscriptItem.swift, Preview/PreviewSessionRequestSender.swift, docc/WritingAClientModelExtension.md, Tests Model/ClientModelExtensionTests.swift, SubagentResumeTests.swift, SubagentTestSupport.swift
    - next: /review
  timestamp: 2026-11-10T16:49:01.432667+00:00
- actor: claude-code
  id: 01m735wppt3gza6rcf9vpnnf87
  text: |-
    Correction: the earlier note names the next task as "^-next". That is not a task id. The next task is 01M730307860SV2CNJHKPKZVQR.

    The session-part tests are now the nested suite `ClientModelExtensionTests.SessionPart`. Thus the filter on the card, `ClientModelExtensionTests|SessionModelMCPServerStatusTests|SessionModelMailPauseTests`, selects them: 70 tests in 5 suites passed. Then `swift test`: 854 tests in 71 suites passed.

    ### implement — changed
    - evidence: swift build (only the allowed mlx metal warning); swift test 854/71 passed; swift test --package-path IntegrationTests 23/5 passed; card filter 70 passed. 14 files plus 1 new file (Model/OpenedSessionExtensions.swift).
    - next: /review
  timestamp: 2026-11-10T16:50:34.842087+00:00
depends_on:
- 01M73027HMPC6MQ49AQ9QHD8D7
position_column: doing
position_ordinal: '80'
title: 'ACPC-4: ClientModelExtension, the session part (state on each SessionModel, `_` session updates)'
---
## What
ACPC-4, the second part. An extension adds observable state to each `SessionModel`, and handles the session updates that it knows.

The `session/update` notifications do not come through `Client` or `ExtensionHandlers` (`ModelClient.sessionUpdate` does nothing). They come through the main-actor event consumer to `SessionModel.fold(_:)` and `engineChange(folding:)` (`Sources/FoundationModelsACPClient/Model/SessionModel.swift`, about line 554). Thus this hook is on the main actor, inside `engineChange`. Today `engineChange` has two hard-coded branches: `_mcp_server_status` (`MCPServerStatusUpdate`) and `_mail_delivery_paused` (`MailDeliveryPause`). The mail pause also clears at a standard `user_message` or `user_message_chunk` update. Thus the hook sees each update, and not only the `_` updates.

Make these changes:
- [x] `Model/ClientModelExtension.swift`: add to the protocol
  - `associatedtype SessionState: AnyObject` (a `@MainActor @Observable` class), and `@MainActor func makeSessionState(for sessionId: SessionId) -> SessionState`.
  - `@MainActor func apply(_ update: SessionUpdate, to state: SessionState) -> Bool`. It sees each update. It gives `true` when the extension took the update. A taken update does not go to the engine and adds no transcript entry. Default: `false`.
  - `@MainActor func didStartSession(state: SessionState, mcpServers: MCPServerListRequest)`: a hook for `session/new` and `session/resume` (see `ConnectionModel+Sessions.swift`, `setMCPServers`), so an extension can seed its state. Default: do nothing.
- [x] `Model/SessionModel.swift`: each `SessionModel` that the `ConnectionModel` makes (also a sub-agent session) gets one state for each extension. `public func extensionState<E: ClientModelExtension>(_ type: E.Type) -> E.SessionState?`, with the metatype key of the last task. In `engineChange(folding:)`, give each update to the extensions in order, before the built-in branches and the engine. The first extension that gives `true` takes it.
- [x] Chunk order: an update goes to the extensions after the chunk buffer flushes, as each other update does, so the applied order is the arrival order.
- [x] Replay, restore and close: `ReplayRollback` (`SessionModel.swift:648`), `restore(_:)` and `resetTranscript()` do not hold `mcpServers` today. Define the rule for the extension state and write it in the doc comments: a replay of `session/resume` makes a new session state through `makeSessionState`, and a rollback puts the earlier state object back. Add the extension states to `ReplayRollback`.
- [x] `ClientModelExtensionContext`: a notification handler can find the `SessionModel` of a `sessionId` and its extension state on the main actor, for a session notification that is not a `session/update`.
- [x] Preview models (`Preview/SessionModel+Preview.swift`) can set an extension state with sample data. DocC: add the session part to the extension article.

## Acceptance Criteria
- [x] A test extension that takes `_test_status` updates changes its session state, and the transcript gets no entry.
- [x] An `_` update that no extension takes becomes an `UnknownEntry`, as today.
- [x] Two extensions: the first in order that gives `true` takes the update, and the second does not see it.
- [x] A test extension sees a standard `user_message_chunk`, gives `false`, and the transcript still gets the entry.
- [x] Each session (also a sub-agent session) has its own state.
- [x] Chunks before and after a taken update keep arrival order.
- [x] A failed replay that rolls back gives back the earlier extension state.
- [x] `SessionModelMCPServerStatusTests` and `SessionModelMailPauseTests` stay green.

## Tests
- [x] Extend `Tests/FoundationModelsACPClientTests/Model/ClientModelExtensionTests.swift` with the cases above. Use `SessionUpdateFixtures.swift` and `CoalescingTestSupport.swift` for the chunk order case, and the replay tests in `SubagentResumeTests.swift` as the model for the rollback case.
- [x] Run `swift test --filter "ClientModelExtensionTests|SessionModelMCPServerStatusTests|SessionModelMailPauseTests"` → all pass. Then `swift test` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1