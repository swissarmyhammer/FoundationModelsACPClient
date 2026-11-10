---
assignees:
- claude-code
depends_on:
- 01M73027HMPC6MQ49AQ9QHD8D7
position_column: todo
position_ordinal: '8280'
title: 'ACPC-4: ClientModelExtension, the session part (state on each SessionModel, `_` session updates)'
---
## What
ACPC-4, the second part. An extension adds observable state to each `SessionModel`, and handles the session updates that it knows.

The `session/update` notifications do not come through `Client` or `ExtensionHandlers` (`ModelClient.sessionUpdate` does nothing). They come through the main-actor event consumer to `SessionModel.fold(_:)` and `engineChange(folding:)` (`Sources/FoundationModelsACPClient/Model/SessionModel.swift`, about line 554). Thus this hook is on the main actor, inside `engineChange`. Today `engineChange` has two hard-coded branches: `_mcp_server_status` (`MCPServerStatusUpdate`) and `_mail_delivery_paused` (`MailDeliveryPause`). The mail pause also clears at a standard `user_message` or `user_message_chunk` update. Thus the hook sees each update, and not only the `_` updates.

Make these changes:
- [ ] `Model/ClientModelExtension.swift`: add to the protocol
  - `associatedtype SessionState: AnyObject` (a `@MainActor @Observable` class), and `@MainActor func makeSessionState(for sessionId: SessionId) -> SessionState`.
  - `@MainActor func apply(_ update: SessionUpdate, to state: SessionState) -> Bool`. It sees each update. It gives `true` when the extension took the update. A taken update does not go to the engine and adds no transcript entry. Default: `false`.
  - `@MainActor func didStartSession(state: SessionState, mcpServers: MCPServerListRequest)`: a hook for `session/new` and `session/resume` (see `ConnectionModel+Sessions.swift`, `setMCPServers`), so an extension can seed its state. Default: do nothing.
- [ ] `Model/SessionModel.swift`: each `SessionModel` that the `ConnectionModel` makes (also a sub-agent session) gets one state for each extension. `public func extensionState<E: ClientModelExtension>(_ type: E.Type) -> E.SessionState?`, with the metatype key of the last task. In `engineChange(folding:)`, give each update to the extensions in order, before the built-in branches and the engine. The first extension that gives `true` takes it.
- [ ] Chunk order: an update goes to the extensions after the chunk buffer flushes, as each other update does, so the applied order is the arrival order.
- [ ] Replay, restore and close: `ReplayRollback` (`SessionModel.swift:648`), `restore(_:)` and `resetTranscript()` do not hold `mcpServers` today. Define the rule for the extension state and write it in the doc comments: a replay of `session/resume` makes a new session state through `makeSessionState`, and a rollback puts the earlier state object back. Add the extension states to `ReplayRollback`.
- [ ] `ClientModelExtensionContext`: a notification handler can find the `SessionModel` of a `sessionId` and its extension state on the main actor, for a session notification that is not a `session/update`.
- [ ] Preview models (`Preview/SessionModel+Preview.swift`) can set an extension state with sample data. DocC: add the session part to the extension article.

## Acceptance Criteria
- [ ] A test extension that takes `_test_status` updates changes its session state, and the transcript gets no entry.
- [ ] An `_` update that no extension takes becomes an `UnknownEntry`, as today.
- [ ] Two extensions: the first in order that gives `true` takes the update, and the second does not see it.
- [ ] A test extension sees a standard `user_message_chunk`, gives `false`, and the transcript still gets the entry.
- [ ] Each session (also a sub-agent session) has its own state.
- [ ] Chunks before and after a taken update keep arrival order.
- [ ] A failed replay that rolls back gives back the earlier extension state.
- [ ] `SessionModelMCPServerStatusTests` and `SessionModelMailPauseTests` stay green.

## Tests
- [ ] Extend `Tests/FoundationModelsACPClientTests/Model/ClientModelExtensionTests.swift` with the cases above. Use `SessionUpdateFixtures.swift` and `CoalescingTestSupport.swift` for the chunk order case, and the replay tests in `SubagentResumeTests.swift` as the model for the rollback case.
- [ ] Run `swift test --filter "ClientModelExtensionTests|SessionModelMCPServerStatusTests|SessionModelMailPauseTests"` → all pass. Then `swift test` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1