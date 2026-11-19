---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7ty343xntn7ft2e61hcsaqf
  text: 'From foundationmodelsacp-be (FoundationModelsACP fb08304): for the read-only model, apply `snapshot.updates` to a merge engine (`SessionMergeEngine(replaying: snapshot.updates)`, or the normal `apply(_:)` path of the model). The title is `snapshot.options.title`: no session_info update is in the snapshot, so the read-only model sets its title from the options. A snapshot from a newer format throws `SessionSnapshot.DecodingError.newerFormat(version:)` at decode time; that is the app''s case, not this model''s.'
  timestamp: 2026-11-19T22:16:02.941283+00:00
- actor: claude-code
  id: 01m7tywq6rxgc5myrrrc5bxf68
  text: |-
    Research (implement):
    - `SessionSnapshot` (FoundationModelsACP fb08304, `ACPMarkdown`) has `updates`, `options` (title), `markdown`, `turnCount`. It has NO session id. Thus the read-only initializer also takes the session id: `SessionModel(snapshot:sessionId:)`. The app has the id in the `SharedItem` record (D208 (b)).
    - The methods of `SessionModel` that send to the agent: `prompt(_:meta:)`, `cancel(meta:)`, `setConfigOption(_:)` (this is also "set mode": this package has no `session/set_mode`; a mode is a config option), `selectPermission`, `cancelPermission`, `acceptElicitation`, `declineElicitation`, `cancelElicitation`, `cancelAllPending`. `stopWaiting(_:)` sends nothing (its doc says so).
    - Fork (and rewind, which is a fork with a `SAH.ForkCut`), resume (with its replay) and delete are on `ConnectionModel` and take a session id. They find only a model in `openSessions`. `close(_:)` takes the model: today a close of a model that is not open still sends `session/close` and calls `unregister(sessionId)`, which can remove a LIVE model with the same id. So `close(_:)` needs the guard too.
    - The permission and elicitation answers are not `throws` today. To throw `readOnly`, they become `throws`. AgentViewKit `PendingElicitationOwner` (non-throwing requirements, `extension SessionModel: PendingElicitationOwner {}`) and its callers must add `try` when they take this sha.
    - Entries that a replay of history adds get no time (`isReplayingHistory`). The entries of a snapshot are history too, so they must get no time.
  timestamp: 2026-11-19T22:30:01.688224+00:00
- actor: claude-code
  id: 01m7v0511xx3bs5ag8nn8kqg9k
  text: |-
    Implementation landed (not committed). CORRECTED after the revision of the coordinator; see the next comments.
    - `SessionModel(snapshot:sessionId:)` (public convenience init, `SessionModel+ReadOnly.swift`). It applies the title of `snapshot.options.title` as a `session_info_update`, then each update of `snapshot.updates`, all through `apply(_:)` with a zero cadence. No second fold. Entries of a read-only model get no time, the same as a replay of history.
    - `public nonisolated let isReadOnly: Bool`, set by the designated init (`isReadOnly: false` by default). No busy state, turn state, counter or event.
    - New `SessionModelError` with `readOnly` and `notReadOnly`. One guard, `requireWritable()`, is the first line of `prompt`, `cancel`, `setConfigOption` (set mode) and `ConnectionModel.close(_:)`. The read-only sender `ReadOnlySessionRequestSender` throws `readOnly` too, as a second barrier.
    - The permission and elicitation answers keep their old signatures (not `throws`). A read-only model has no connection, so its pending lists are always empty. No API change for AgentViewKit.
    - No fork overload. `forkSession(_ sessionId:cut:)` with the id of a read-only model throws `sessionNotOpen` and sends nothing (when no live model of that id is open). Resume (with replay) and delete take an id or a request, so they never change a read-only model. This is documented on the initializer.
    - `replace(with:)`: when the current engine entries are the first entries of the newer snapshot (same ids), it applies the replay update of each changed or new entry through `apply(_:)`: same objects and ids, changed entries in place, new entries at the end. Else, or when the result is not the newer entries, it calls `resetTranscript()` and applies all updates again (new objects; a view can lose its scroll position). On a model that is not read-only it throws `notReadOnly` and changes nothing.
  timestamp: 2026-11-19T22:52:02.493399+00:00
- actor: claude-code
  id: 01m7v0546tm2wfdkpcdrwaj67j
  text: |-
    ### implement — changed
    - evidence: new files Sources/FoundationModelsACPClient/Model/{SessionModel+ReadOnly,SessionModelError,ReadOnlySessionRequestSender}.swift and Tests/FoundationModelsACPClientTests/Model/SessionModelReadOnlyTests.swift; changed SessionModel.swift, SessionModel+Pending.swift, SessionModel+Prompt.swift, SessionModel+Stream.swift, ConnectionModel+Sessions.swift, 21 test files in Tests/ (`try` for the answer methods, new fork and close tests), 2 files in IntegrationTests/. `timeout 1800 swift build`: clean (only the MLX warning). `timeout 1800 swift test`: 969 tests in 79 suites passed. `swift build --build-tests --package-path IntegrationTests`: clean (only the MLX warning). Live integration tests not run.
    - next: /review. Not committed, not pushed. The push acceptance item stays open.
  timestamp: 2026-11-19T22:52:05.722402+00:00
- actor: claude-code
  id: 01m7v0a40dr1ss9h3yb91md1bj
  text: |-
    Revision from the coordinator:
    - Reverted: the answer methods (`selectPermission`, `cancelPermission`, `acceptElicitation`, `declineElicitation`, `cancelElicitation`, `cancelAllPending`) are not `throws` again. `SessionModel+Pending.swift`, `SessionModel+Stream.swift`, each `try` in Tests/ and IntegrationTests/, and `observationFires` are back to `HEAD`. Their 6 tests are removed. The initializer doc says that the pending lists of a read-only model are always empty. The earlier note about an AgentViewKit break is no longer true: there is no break.
    - Removed: the overload `ConnectionModel.forkSession(_ session: SessionModel, cut:)` and its 3 tests. New test `aForkOfTheSessionIdOfAReadOnlyModelThrowsNotOpenAndSendsNothing` in `ConnectionModelForkTests.swift`. The initializer doc tells this.
    - Kept: `isReadOnly`, `requireWritable()` on `prompt`, `cancel`, `setConfigOption`, the guard on `close(_:)`, `replace(with:)`, `notReadOnly`, `SessionModel(snapshot:sessionId:)`.
  timestamp: 2026-11-19T22:54:49.357702+00:00
- actor: claude-code
  id: 01m7v0a70s0wxb58bcjs6dvsfc
  text: |-
    ### implement — changed
    - evidence: new files Sources/FoundationModelsACPClient/Model/{SessionModel+ReadOnly,SessionModelError,ReadOnlySessionRequestSender}.swift and Tests/FoundationModelsACPClientTests/Model/SessionModelReadOnlyTests.swift; changed Sources/.../SessionModel.swift, SessionModel+Prompt.swift, ConnectionModel+Sessions.swift, Tests/.../ConnectionModelForkTests.swift, ConnectionModelSessionTests.swift. `timeout 1800 swift build`: clean (only the MLX warning). `timeout 1800 swift test`: 961 tests in 79 suites passed. `swift build --build-tests --package-path IntegrationTests`: clean (only the MLX warning). Live integration tests not run.
    - next: /review. Not committed, not pushed. The push acceptance item stays open.
  timestamp: 2026-11-19T22:54:52.441521+00:00
- actor: claude-code
  id: 01m7v0cww1eh0axm15vdgx7bjc
  text: |-
    ### test — green
    - evidence: `timeout 1800 swift test` exit 0, 961 tests in 79 suites passed, 0 failed, 0 skipped. `swift build --build-tests --package-path IntegrationTests` built clean (build only).
    - warnings: only the allowed MLX "missing creator for mutated node" warning for mlx-swift_Cmlx.bundle.
    - answer methods: grep of `git diff HEAD -- Sources` for selectPermission, cancelPermission, acceptElicitation, declineElicitation, cancelElicitation, cancelAllPending shows no changed signature line.
    - next: review
  timestamp: 2026-11-19T22:56:20.353259+00:00
- actor: claude-code
  id: 01m7v0ddb76kcfz1sskk7x3sxh
  text: |-
    ### commit — changed
    - evidence: local commit made, subject "feat(model): add a read-only SessionModel from a snapshot". Not pushed.
    - next: review or push as the caller decides.
  timestamp: 2026-11-19T22:56:37.223792+00:00
- actor: claude-code
  id: 01m7v0hw9p76yrptnbxkfe7am0
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (5238304); 3 findings — Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift:1333, Tests/FoundationModelsACPClientTests/Model/SessionModelReadOnlyTests.swift:31, Tests/FoundationModelsACPClientTests/Model/SessionModelReadOnlyTests.swift:34
    - next: implement the 3 findings in the "Review Findings (2026-11-19 16:56)" section. Then test, commit and review again.
  timestamp: 2026-11-19T22:59:03.606012+00:00
- actor: claude-code
  id: 01m7v0jfc4sdxkm1brwd60nv31
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 4 new files and 5 changed files (first pass changed the answer methods and added a fork overload; both reverted by decision)
    - test: green — swift test, 961 passed, 0 failed, 0 skipped; IntegrationTests build complete; no answer-method signature changed; only the allowed MLX warning
    - commit: 5238304
    - review: findings — Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift:1333, Tests/FoundationModelsACPClientTests/Model/SessionModelReadOnlyTests.swift:31, Tests/FoundationModelsACPClientTests/Model/SessionModelReadOnlyTests.swift:34
  timestamp: 2026-11-19T22:59:23.140339+00:00
- actor: claude-code
  id: 01m7v0q9zaf086yy68tyqfw3fv
  text: |-
    Fixes of the 3 review findings (2026-11-19 16:56):
    - ConnectionModelSessionTests.swift: `aCloseOfAReadOnlyModelKeepsTheOpenModelOfTheSameSession` now asserts `SessionModelError.readOnly` with `#expect(throws:)`, and keeps the identity assertion. The other new tests of the commit in this file had no other `try?`. ConnectionModelForkTests.swift has no `try?` in its new test.
    - SessionModelReadOnlyTests.swift: the same cause (`try?` hides the refusal) was also in the "SendsNothing" tests (prompt two times, cancel, set mode) and in `aReplaceOnAModelOfAConnectionChangesNothing`. Each now asserts the error (`readOnly` or `notReadOnly`) with `#expect(throws:)`, and keeps its own assertion.
    - SessionModelReadOnlyTests.swift: each turn number is now a named constant in `ReadOnlyFixtures` (`firstTurnNumber`, `secondTurnNumber`, `thirdTurnNumber`, `fourthTurnNumber`), in the `static let` style of the other test fixtures. No other literal number is in the file.
  timestamp: 2026-11-19T23:02:01.450531+00:00
- actor: claude-code
  id: 01m7v0qc65tvp7z94w56z4e9jn
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelReadOnlyTests.swift. `swift build --build-tests`: Build complete, only the allowed MLX warning. `swift test`: 961 tests in 79 suites passed, only the allowed MLX warning.
    - next: test, commit, then review again. The acceptance item "Push main, and send the sha" stays open.
  timestamp: 2026-11-19T23:02:03.717536+00:00
- actor: claude-code
  id: 01m7v0s5ejca38t665wd4dq650
  text: |-
    ### test — green
    - evidence: swift test (root) — 961 tests in 79 suites passed, 0 failed, 0 skipped. swift build --build-tests --package-path IntegrationTests — Build complete, exit 0.
    - warnings: only the allowed MLX "missing creator for mutated node" warning for mlx-swift_Cmlx.bundle. No other warning.
    - next: review
  timestamp: 2026-11-19T23:03:02.354792+00:00
- actor: claude-code
  id: 01m7v0sm2am7pwg0r3hvr6jzas
  text: |-
    ### commit — changed
    - evidence: 17cbd0f test(model): assert the read-only errors and name the turn numbers
    - next: review
  timestamp: 2026-11-19T23:03:17.322874+00:00
- actor: claude-code
  id: 01m7v0vhs70yw967ypmn7g70hm
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 6f61b1a). The review examined 2 files. It found 0 findings: 0 confirmed, 0 refuted, 7 validator runs, 0 failed. The 3 earlier items in "Review Findings (2026-11-19 16:56)" are all checked.
    - next: The task is in done. The acceptance item "Push `main`, and send the sha to agentviewkit-0b and testudoapp-9a" is not checked yet. It is not a review finding.
  timestamp: 2026-11-19T23:04:20.519405+00:00
- actor: claude-code
  id: 01m7v0vvj828z5z0jb8nn57gjz
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 2 test files (`#expect(throws:)` in place of `try?`, named turn constants)
    - test: green — swift test, 961 passed, 0 failed, 0 skipped; IntegrationTests build complete; only the allowed MLX warning
    - commit: 6f61b1a
    - review: clean — 0 findings; the 3 earlier findings are checked
  timestamp: 2026-11-19T23:04:30.536451+00:00
depends_on:
- 01M7TXXY981MZ52MSTBDJ6NDT9
position_column: done
position_ordinal: ffbf80
title: A read-only SessionModel from a share snapshot, with replace(with:) (D208)
---
## External dependency: do not start before it is on main

FoundationModelsACP must have `SessionSnapshot` on `main` (foundationmodelsacp-be sends the sha). This task also depends on 01M7TXXY981MZ52MSTBDJ6NDT9.

## Goal

A recipient of a shared session sees a read-only tab with no composer (D208 (g), (i), TestudoApp/features/decisions.md, commit d803f1a). AgentViewKit shows the chat of a `SessionModel` that has no connection and refuses each request.

Brief: /Users/wballard/github/swissarmyhammer/.briefs/share/acpc-brief.md (items 2 and 3).

## Current state

- `SessionModel.apply(_:)` folds one `SessionUpdate` (`Sources/FoundationModelsACPClient/Model/SessionModel.swift`).
- A `SessionModel` is made by the `ConnectionModel` for `session/new`, `session/resume` and `session/fork`, with a connection.

## Change

1. A read-only model from a snapshot: `SessionModel(snapshot:)` (or a factory; the session can choose). It applies the updates of the snapshot in order, with no connection. It is not in any `openSessions`.
2. `public let isReadOnly: Bool` (or a computed property): `true` for this model, `false` for each model of a connection. It is a property of the kind of model that never changes for the life of the model. Do NOT add a busy state, turn state or event (rule of this repo).
3. Each request on a read-only model (prompt, cancel, fork, rewind or replay, set mode, set config option, and each other method that sends to the agent) throws a new error `readOnly` before it sends anything. Find each such method; do not miss one. Prefer one guard that all of them use.
4. `public func replace(with snapshot: SessionSnapshot)` on a read-only model: the app calls it when Update Share gives a newer snapshot. Entries that stay the same keep their object identity and their `id` (so the view keeps its scroll position). New entries are added at the end. Changed entries update in place. If the newer snapshot does not start with the same entries, the model may rebuild; document what happens. On a model that is not read-only, `replace(with:)` throws `readOnly`'s opposite case or a precondition error: choose and document.
5. Doc comments in STE.

## Tests (Swift Testing)

- [x] A model from a snapshot shows the same transcript (ids and texts) as a live model that got the same updates.
- [x] `isReadOnly` is `true` for it, `false` for a model of a connection.
- [x] A prompt, a cancel, a fork and a set mode on a read-only model each throw `readOnly`, and nothing is sent.
- [x] `replace(with:)` with a snapshot that has two more turns adds them, and the old entries keep their object identity.

## Acceptance

- [x] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [x] Push `main`, and send the sha to agentviewkit-0b and testudoapp-9a. #d208

## Review Findings (2026-11-19 16:56)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift:1333` `test-integrity/no-test-cheating` — The test discards the error of `close(shared)` with `try?`, so it does not prove the refusal. The test passes if the close throws any error, including an unrelated one such as `ConnectionError.closed`, or if the close is refused for another reason. The test should assert that the call throws `SessionModelError.readOnly`, as the sibling test at line 1320 does. The surviving assertion on line 1335 still fails if the model is unregistered, so the test is not vacuous. The gap is that the refusal itself is never proven. Replace `try? await connected.model.close(shared)` with `await #expect(throws: SessionModelError.readOnly) { try await connected.model.close(shared) }`, and keep the identity assertion on line 1335.
- [x] `Tests/FoundationModelsACPClientTests/Model/SessionModelReadOnlyTests.swift:31` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsACPClientTests/Model/SessionModelReadOnlyTests.swift:34` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.