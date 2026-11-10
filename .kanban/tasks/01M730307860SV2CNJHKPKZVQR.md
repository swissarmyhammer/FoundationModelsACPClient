---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m736cbyjk33z18vr50snnbb0
  text: |-
    Research (implement):
    - Many tests make a bare SessionModel (SessionModelFixtures.makeModel, SessionModel(sessionId:requestSender:)) with no extension factories, and the MCP and mail tests use it. Thus the default `extensionFactories` of SessionModel.init must be the factories of the two built-in extensions. ConnectionModel puts the built-ins first in its `extensions` list in init, so `openedExtensions.sessionFactories` has them first. SessionModel.preview puts them before the `extensions:` of the host.
    - The two extension types stay internal: a host reads `mcpServers` and `mailDeliveryPause`, and cannot add a second extension of the same type.
    - `public internal(set) var mcpServers` and `mailDeliveryPause` become computed properties with the same spelling. The getter reads the extension state, so observation tracks `sessionExtensions` and the observable state. The internal setter writes the state, so `runReplay` (restore of the list on a refused resume, also for a resume with no history) and the prompt (clear of the pause) need no other change.
    - Behavior note: a replay with history now makes a new mail-pause state (rule of the extension point), so the pause is nil at the start of such a replay until the replay gives the pause again. The existing tests (aReplayFromTheStartSetsThePauseAgain, aReplayWithALaterUserMessageClearsThePause, aResumeWithNoReplayKeepsThePause) hold with no change. The doc of mailDeliveryPause will state the new rule.
    - `setMCPServers` moves from SessionModel to the state of the MCP extension; the preview and the test fixture call it there.
  timestamp: 2026-11-10T16:59:08.114514+00:00
- actor: claude-code
  id: 01m736tk0qbp3csxy8fvtam1qf
  text: |-
    Implementation landed (TDD).
    - RED: theListIsInTheSessionStateOfTheBuiltInExtension and thePauseIsInTheSessionStateOfTheBuiltInExtension did not compile (no MCPServerStatusExtension / MailDeliveryPauseExtension). The two order tests (aHostExtensionOfAPreview/OfTheConnectionDoesNotGetAnUpdateThatABuiltInExtensionTook) were checked RED after GREEN: with the extension order reversed for one run, both failed; the order was then put back.
    - The two observation tests (anObserverOfTheListGetsTheItemOfANewServer, anObserverOfThePauseGetsTheClearOfAUserMessage) use waitForObservation with noFailureEvent: the change runs in a main-actor Task after the wait starts to track, so only the observation ends the wait. They also pass at HEAD (they guard the refactor).
    - New: Model/MCPServerStatusExtension.swift, Model/MailDeliveryPauseExtension.swift. ClientModelExtension.swift gained BuiltInClientModelExtensions (the list and its session factories) and EmptyExtensionConnectionState.
    - SessionModel: engineChange(folding:) has only the extension take, the correlator and the engine. setMCPServers and applyMCPServerStatus moved into MCPServerStatusExtension.SessionState (replaceServers(with:), apply(_:)). mcpServers and mailDeliveryPause are computed `public internal(set)` properties over the extension states, so the public spelling does not change. The default extensionFactories of SessionModel.init is the built-ins; ConnectionModel.makeSessionModel falls back to the built-ins before the first connect; SessionModel.preview puts the built-ins first.
    - runReplay keeps its restore of mcpServers on a refused request (a resume with no history has no rollback); a comment states why.
    - Docs: SessionModel type doc, mcpServers, mailDeliveryPause (new replay rule), fold, engineChange, ReplayRollback; ClientModelExtension.apply; ConnectionModel.addExtension and makeSessionModel; preview `extensions:`; WritingAClientModelExtension.md.
    - Only one test fixture line changed (StatusFixtures.modelWithClientServers calls replaceServers(with:)); no assertion changed.
  timestamp: 2026-11-10T17:06:54.103588+00:00
- actor: claude-code
  id: 01m736tp7y6j6mphn6wj1pg740
  text: |-
    ### implement — changed
    - evidence: swift build (only the allowed mlx metal warning); card filter SessionModelMCPServerStatusTests|SessionModelMailPauseTests|ClientModelExtensionTests 76 tests in 5 suites passed; swift test 860 tests in 71 suites passed; swift test --package-path IntegrationTests 23 tests in 5 suites passed. Files: new Model/MCPServerStatusExtension.swift, Model/MailDeliveryPauseExtension.swift; changed Model/ClientModelExtension.swift, Model/ConnectionModel.swift, Model/ConnectionModel+Sessions.swift, Model/SessionModel.swift, Preview/SessionModel+Preview.swift, docc/WritingAClientModelExtension.md, Tests Model/ClientModelExtensionTests.swift, Model/SessionModelMCPServerStatusTests.swift, Model/SessionModelMailPauseTests.swift.
    - next: /review
  timestamp: 2026-11-10T17:06:57.406385+00:00
depends_on:
- 01M7302MHW9G50K9NMMQSGVQNH
position_column: doing
position_ordinal: '80'
title: 'ACPC-4: move _mcp_server_status and _mail_delivery_paused onto the extension point'
---
## What
Prove the session part of ACPC-4 with the two built-in `_` session updates. After this task, `SessionModel` has no hard-coded `_` update branch.

Make these changes:
- [x] New `Sources/FoundationModelsACPClient/Model/MCPServerStatusExtension.swift`: a `ClientModelExtension` whose session state holds the `[MCPServerItem]` list. It takes `_mcp_server_status` (with `MCPServerStatusUpdate.decode`) and seeds the list from the `session/new` / `session/resume` request in `didStartSession` (the logic that `SessionModel` has today for `mcpServers`).
- [x] New `Sources/FoundationModelsACPClient/Model/MailDeliveryPauseExtension.swift`: a `ClientModelExtension` whose session state holds `MailDeliveryPause?`. It takes `_mail_delivery_paused`. It clears the pause at a `user_message` or `user_message_chunk` update. Thus the extension must see these updates and give `false` for them, so they still go to the engine.
- [x] `ConnectionModel` registers the two built-in extensions in its initializer, before each host extension.
- [x] `Model/SessionModel.swift`: remove the two branches from `engineChange(folding:)`. `public var mcpServers` and `public var mailDeliveryPause` stay as public read-only properties that read the extension state, so no host code changes. Observation of them must still report each change.
- [x] Update the doc comments of `SessionModel` that name the two updates.

## Acceptance Criteria
- [x] `engineChange(folding:)` has no `MCPServerStatusUpdate` or `MailDeliveryPause` branch.
- [x] The public API of `SessionModel.mcpServers` and `SessionModel.mailDeliveryPause` does not change.
- [x] All existing tests pass with no change of their assertions.

## Tests
- [x] `Tests/FoundationModelsACPClientTests/Model/SessionModelMCPServerStatusTests.swift` and `SessionModelMailPauseTests.swift` stay green with no change to the assertions. Add one test to each that observes the property (`ObservationWait.swift`) and asserts the change is reported.
- [x] Run `swift test --filter "SessionModelMCPServerStatusTests|SessionModelMailPauseTests|ClientModelExtensionTests"` → all pass. Then `swift test` → all pass, and the `IntegrationTests` package (`swift test --package-path IntegrationTests`) → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1