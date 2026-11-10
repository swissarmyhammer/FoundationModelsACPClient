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
- actor: claude-code
  id: 01m7374pg53405844qh72brtd5
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (8d9c81b): 2 findings (2 confirmed, 4 refuted). Sources/FoundationModelsACPClient/Model/MCPServerStatusExtension.swift:60, Sources/FoundationModelsACPClient/Model/MailDeliveryPauseExtension.swift:29 (`reuse/reuse`, the copied no-op `registerHandlers`).
    - Caller check 1 (replay with history starts with no mail pause): the doc comment of `SessionModel.mailDeliveryPause` and of `ReplayRollback` state the new rule, and the commit message states it. The tests `aReplayFromTheStartSetsThePauseAgain`, `aReplayWithALaterUserMessageClearsThePause` and `aResumeWithNoReplayKeepsThePause` stay green. The file header comment of SessionModelMailPauseTests.swift still says "A replay keeps it until it gives a later user message". That line did not change in this commit, so it is not a finding of this diff review.
    - Caller check 2 (observation tests that can hang): `noFailureEvent` in ObservationWait.swift is a written, allowed choice "only when no event can tell that the change will never come", with the reason in a comment at the call site. Both new tests have that comment. A `TaskEnd` failure event does not work here: when the task ends, the value already changed, so the wait passes also when observation did not report the change. The same pattern is in ChunkCoalescerTests.swift and ConnectionModelTests.swift. Thus the tests obey rule T1 as written. No finding.
    - Caller check 3 (`runReplay` restores `mcpServers`): yes. ConnectionModel+Sessions.swift keeps `mcpServersBeforeResume` and sets `session.mcpServers` back in the `catch` of the refused resume, before `endReplay(of:afterFailure:)`. For a replay with history, the rollback then puts back the earlier state objects. No finding.
    - next: implement the 2 findings, then review again.
  timestamp: 2026-11-10T17:12:25.349241+00:00
- actor: claude-code
  id: 01m73757cvtxgkeqxeg52xwnqa
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 11 files (2 new)
    - test: green — swift test 860/860, IntegrationTests 23/23
    - commit: 8d9c81b (pushed)
    - review: findings — Sources/FoundationModelsACPClient/Model/MCPServerStatusExtension.swift:60, Sources/FoundationModelsACPClient/Model/MailDeliveryPauseExtension.swift:29
  timestamp: 2026-11-10T17:12:42.651248+00:00
- actor: claude-code
  id: 01m737asa8q1axe3nc9e4q0y1q
  text: |-
    Implement of the 2 review findings (reuse/reuse, the copied no-op registerHandlers).
    - ClientModelExtension.swift: new constrained extension `extension ClientModelExtension where ConnectionState == EmptyExtensionConnectionState`. It holds the one empty `registerHandlers(into:context:)` and the one `makeConnectionState()` that gives a new `EmptyExtensionConnectionState`. The members are internal, because `EmptyExtensionConnectionState` is internal.
    - Same cause, whole files: the two built-in extensions also had the same copied `makeConnectionState()` default. Both copies are deleted, and both copies of `registerHandlers` are deleted. `makeSessionState(for:)` stays in each type: each one makes a different `SessionState` type, so it is not a copied default.
    - Discovery: the compiler infers `ConnectionState == EmptyExtensionConnectionState` from the constrained default, so the two types need no `typealias ConnectionState`. A first try with a `typealias` in each type also compiled; it was removed, because it was one more copied line.
    - SessionModelMailPauseTests.swift: the header comment now says that a replay with history starts with no pause, a replayed pause sets it again, a later replayed user message clears it, a failed replay gives the earlier pause back, and a resume with no history and the close keep it. This agrees with the doc of SessionModel.mailDeliveryPause.
    - No new test: this is a refactor with no change of behavior. The existing tests of the two extensions cover it.
  timestamp: 2026-11-10T17:15:44.840171+00:00
- actor: claude-code
  id: 01m737avqse7ydzjp8kxnd781g
  text: |-
    ### implement — changed
    - evidence: swift build (only the allowed mlx metal warning); swift test 860 tests in 71 suites passed. Files: Sources/FoundationModelsACPClient/Model/ClientModelExtension.swift, Sources/FoundationModelsACPClient/Model/MCPServerStatusExtension.swift, Sources/FoundationModelsACPClient/Model/MailDeliveryPauseExtension.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelMailPauseTests.swift. Both findings are `- [x]`.
    - next: /review
  timestamp: 2026-11-10T17:15:47.321872+00:00
- actor: claude-code
  id: 01m737znv4fhhxzmwtb9312c71
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (377322f), 1 finding — Tests/FoundationModelsACPClientTests/Model/SessionModelMailPauseTests.swift:12 (completeness/inverse-operation-coverage). The 2 prior reuse findings are checked.
    - next: add a failed-replay test for mailDeliveryPause in SessionModelMailPauseTests.swift, then review again.
  timestamp: 2026-11-10T17:27:09.412950+00:00
- actor: claude-code
  id: 01m73802ynq1ky5exf12021t89
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 4 files (one shared empty default)
    - test: green — swift test 860/860; IntegrationTests 1 flaky timeout in the first run (task 01M737WW16), 23/23 in the second run
    - commit: 377322f (pushed)
    - review: findings — Tests/FoundationModelsACPClientTests/Model/SessionModelMailPauseTests.swift:12
  timestamp: 2026-11-10T17:27:22.837853+00:00
- actor: claude-code
  id: 01m7384r6wkj9hgmqebc6td811
  text: |-
    Implement of the finding SessionModelMailPauseTests.swift:12 (completeness/inverse-operation-coverage).
    - New test aFailedReplayGivesBackTheEarlierPause in SessionModelMailPauseTests.swift: set a pause, beginReplay(replayFromStart), fold a replayed user message, endReplay(succeeded: false), expect the earlier pause.
    - Same cause for mcpServers: the doc of SessionModel.ReplayRollback says that a failed replay gives back mcpServers, and no test did it. New test aFailedReplayGivesBackTheEarlierList in SessionModelMCPServerStatusTests.swift (new MARK Replay): two client servers, files connected, beginReplay, fold a config server update, endReplay(succeeded: false), expect the earlier list. The file header now states the rule.
    - The two tests passed at once, because the rollback code is correct. To prove that they can fail, `sessionExtensions = rollback.sessionExtensions` in restore(_:) was removed for one run: both tests failed. The source file was then put back (git diff shows no change to SessionModel.swift). No production code changed.
  timestamp: 2026-11-10T17:29:55.676833+00:00
- actor: claude-code
  id: 01m7384t6ghpgt2g4xakxswcqf
  text: |-
    ### implement — changed
    - evidence: swift build (only the allowed mlx metal warning); swift test 862 tests in 71 suites passed. Files: Tests/FoundationModelsACPClientTests/Model/SessionModelMailPauseTests.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelMCPServerStatusTests.swift. The finding is `- [x]`.
    - next: /review
  timestamp: 2026-11-10T17:29:57.712893+00:00
- actor: claude-code
  id: 01m738b2519ffpte4wyn6vb0bz
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (a58423a): 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. All prior findings are checked.
    - next: none. The task is in done.
  timestamp: 2026-11-10T17:33:22.465470+00:00
- actor: claude-code
  id: 01m738bdmykbspc1n72w4xt6vf
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — 2 test files (rollback tests)
    - test: green — swift test 862/862, IntegrationTests 23/23
    - commit: a58423a (pushed)
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-10T17:33:34.238299+00:00
depends_on:
- 01M7302MHW9G50K9NMMQSGVQNH
position_column: done
position_ordinal: ffaa80
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

## Review Findings (2026-11-10 11:10)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsACPClient/FoundationModelsACPClient.docc/WritingAClientModelExtension.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPClient/Model/MCPServerStatusExtension.swift:60` `reuse/reuse` — The no-op `registerHandlers(into:context:)` repeats the same empty method in `MailDeliveryPauseExtension`. Remove this method and use one shared default no-op, as described in the finding on MailDeliveryPauseExtension.swift:29.
- [x] `Sources/FoundationModelsACPClient/Model/MailDeliveryPauseExtension.swift:29` `reuse/reuse` — The no-op `registerHandlers(into:context:)` is copied from `MCPServerStatusExtension`. Both built-in extensions register no handlers, so the same empty body appears twice. Move the empty `registerHandlers` into a protocol extension that requires `ConnectionState == EmptyExtensionConnectionState`, as described for `makeConnectionState()`. Delete this copy.

## Review Findings (2026-11-10 11:26)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Tests/FoundationModelsACPClientTests/Model/SessionModelMailPauseTests.swift:12` `completeness/inverse-operation-coverage` — The new header comment says a failed replay gives the earlier mail pause back. No test in this file exercises that case. Every replay test here uses endReplay(succeeded: true). The only failed-replay tests (aFailedReplayGivesBackTheEarlierSessionState in ClientModelExtensionTests.swift and the aFailedReplay* tests in SessionModelStreamTests.swift) check session status or live history, not mailDeliveryPause. So the documented rule is unproven, and a regression in the pause restore would pass the suite. Add one test in SessionModelMailPauseTests.swift that sets a pause, runs beginReplay, then endReplay(succeeded: false), and asserts mailDeliveryPause still holds the earlier pause. Alternatively, reword the comment if the rollback is not meant to cover the pause.
