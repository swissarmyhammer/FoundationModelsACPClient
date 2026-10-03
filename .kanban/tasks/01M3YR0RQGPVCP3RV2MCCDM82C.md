---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3ywyds9x48cmg1g99h3p3gb
  text: 'Name correction (seen on upstream main 0d3e88a, 2026-10-02): the subscription field is `SessionUpdateSubscription.hasMissedUpdates`, not `missedUpdates`. Use the upstream name where this task says `missedUpdates`. The same applies to task 6np8vdv.'
  timestamp: 2026-10-02T18:10:10.857953+00:00
- actor: claude-code
  id: 01m412t160qvg4hrtbgqv0xxpw
  text: 'From ^65x5kjr: `SessionModel` now has internal `finishUpdateTaps()` (in `SessionModel+Coalescing.swift`), which finishes each `updateTap()` stream. `markClosed()` must call `flushPendingChunks()` and then `finishUpdateTaps()`. When the attached subscription ends, call `finishUpdateTaps()` too. `apply(_:)` now buffers chunks with the 33 ms default cadence; a test that needs each chunk at once makes the model with `coalescingCadence: .zero`.'
  timestamp: 2026-10-03T14:31:07.200373+00:00
- actor: claude-code
  id: 01m417fc38dhnqs86e894z2gxy
  text: |-
    Research (implement start):
    - `SessionUpdateSubscription` (FoundationModelsACP 284e002) has no public init. It has only the implicit internal memberwise init `init(updates:hasMissedUpdates:)`. The test makes a hand-made subscription through `@testable import FoundationModelsACP` (SwiftPM debug builds compile each module with testability).
    - `ReplayFrom` is an enum: `.start(ReplayFromStart)` and an unknown case. `ResumeSessionRequest.replayFrom: ReplayFrom?`.
    - `SessionModel` keeps the engine, `wireEntries`, `heldEchoes`, `unlinkedPrompts` and `promptCorrelator` `private` in SessionModel.swift. An extension in another file cannot reset them. So the transcript reset goes in SessionModel.swift, and the stream life (attach, replay, close) goes in the new SessionModel+Stream.swift. The new stored properties (`hasMissedUpdates`, `isReplaying`, `history`, `isClosed`, the stream task) must also go in the class body, because an extension cannot hold stored properties.
    - Plan: `apply(_:)` changes nothing after close. A reset also moves the elicitation links of the old tool-call objects back to `unresolvedElicitationLinks`, so the new replayed tool-call entry takes them.
  timestamp: 2026-10-03T15:52:40.808319+00:00
- actor: claude-code
  id: 01m417xw5yh9xvg85716g02p3f
  text: |-
    Implementation landed (TDD). RED: `swift build --build-tests` failed only with "value of type 'SessionModel' has no member" for attach, beginReplay, endReplay, hasMissedUpdates, history, isClosed, isReplaying and markClosed. The `@testable import FoundationModelsACP` and the hand-made `SessionUpdateSubscription(updates:hasMissedUpdates:)` compiled. GREEN: 27 tests in SessionModelStreamTests pass.

    Decisions and discoveries for the next agent (ConnectionModel tasks ^1qvf, ^6np8vdv):
    - `beginReplay(replayFrom:)` resets only when `replayFrom != nil` AND the transcript is not empty. A resume with `replayFrom == nil` keeps the transcript, the state and `history`.
    - `history` changes in `endReplay(succeeded: true)` only (a failed replay keeps `.live`). The cursor is kept in the internal `replayPhase` enum (`.idle` / `.replaying(from:)`); `isReplaying` is computed from it.
    - `endReplay` flushes the chunk buffer, so the replayed text is complete when the replay ends.
    - ORDER RISK for ConnectionModel: the replay updates come through the stream task, which is asynchronous. A `session/resume` response can reach the caller before the stream task has applied every replayed update. ConnectionModel must not assume that the transcript is complete at `endReplay`. This model does not wait for the stream.
    - The reset moves the elicitation links of the old tool-call entries back to `unresolvedElicitationLinks` (new `detachElicitationLinksFromToolCalls()` in +Pending), so the replayed tool-call entry takes the link of a pending elicitation.
    - The reset also clears the prompt link state (unlinkedPrompts, heldEchoes, a new PendingPromptCorrelator). A prompt that is in flight across a replay resolves with no link and no defect.
    - The stream task holds the model weakly; `deinit` cancels it. When the subscription ends by itself, the taps end; when the close or a second `attach` cancels the task, the task does not end the taps.
    - `updateTap()` after close returns a stream that is already finished.
  timestamp: 2026-10-03T16:00:36.030402+00:00
- actor: claude-code
  id: 01m417y2699ake33qxm5n2ys49
  text: |-
    Correction to the comment above: the ConnectionModel tasks are ^jge1qvf and ^6np8vdv. "^1qvf" is not a task id.

    ### implement — changed
    - evidence: 6 files. Changed: Sources/FoundationModelsACPClient/Model/SessionModel.swift, Model/SessionModel+Coalescing.swift, Model/SessionModel+Pending.swift. New: Model/SessionModel+Stream.swift, Model/SessionHistory.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift. `swift test --filter SessionModelStreamTests`: 27 tests in 1 suite passed. `swift build`: Build complete; only the accepted MLX warning "missing creator for mutated node" and the permitted `SessionUpdateAggregator` deprecations. `swift test`: 393 tests in 33 suites passed, 0 failures. FoundationModelsACP pin not changed (284e002). Not committed.
    - next: /review
  timestamp: 2026-10-03T16:00:42.185880+00:00
- actor: claude-code
  id: 01m4185hp3n4cnm0ksch7hnnzb
  text: |-
    ### test — green
    - evidence: swift build (root) complete. swift test (root) run 2 times: 393 tests in 33 suites passed each time, 0 failures, 0 skipped. SessionModelStreamTests passed both times. swift build --package-path IntegrationTests complete. swift test --package-path IntegrationTests: 103 tests in 14 suites passed, 0 failures, 0 skipped.
    - warnings: only accepted ones (mlx-swift_Cmlx.bundle "missing creator for mutated node", and SessionUpdateAggregator deprecations in ACPSessionState.swift).
    - next: review
  timestamp: 2026-10-03T16:04:47.427606+00:00
- actor: claude-code
  id: 01m4185vv09n3ts7n4wdc5269z
  text: |-
    ### commit — changed
    - evidence: feat(model): attach SessionModel to its subscription, add replay, missed updates and close. Tests: swift test 393/393 two times, IntegrationTests 103/103.
    - next: review
  timestamp: 2026-10-03T16:04:57.824937+00:00
- actor: claude-code
  id: 01m418es56ynwvdkthxewbz8fe
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit cacd4ce). counts: 1 finding, 1 confirmed, 0 refuted. Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift:77 (reuse/reuse: `joinedText()` is a duplicate of the function in SessionModelCoalescingTests.swift).
    - next: /implement the open item in the "Review Findings (2026-10-03 11:05)" section, then /review again.
  timestamp: 2026-10-03T16:09:49.990735+00:00
- actor: claude-code
  id: 01m418f0f2dm29z1bmt8kpf0s0
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files (SessionModel+Stream.swift, SessionHistory.swift, 27 new tests)
    - test: green — swift test 393/393 x2, IntegrationTests 103/103
    - commit: cacd4ce feat(model): attach SessionModel to its subscription, add replay, missed updates and close
    - review: findings — Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift:77
  timestamp: 2026-10-03T16:09:57.474290+00:00
- actor: claude-code
  id: 01m418vdse06eq90jp16df9mbr
  text: |-
    Finding fix (reuse/reuse, joinedText copy). Research: the Model test files had more copied helpers than joinedText. Copies found and removed:
    - `joinedText(_:)`: SessionModelStreamTests and SessionModelCoalescingTests.
    - `immediateModel()` (zero cadence model): SessionModelStreamTests; the same construction in SessionModelFoldTests `foldedModel` and in one SessionModelCoalescingTests test.
    - The buffered model (40 ms cadence + ManualClock): `coalescingModel(clock:)` in SessionModelCoalescingTests, two inline copies in SessionModelStreamTests, and the 40 ms cadence constant in SessionModelPromptTests.
    - `permissionRequest`: SessionModelPendingTests (two options) and SessionModelStreamTests (one option), with the allow/reject options.
    - The usage fixture (200_000 / 1_500): SessionModelFoldTests and SessionModelStreamTests.

    New shared file Tests/FoundationModelsACPClientTests/Model/SessionModelFixtures.swift: an `enum SessionModelFixtures` namespace (the same shape as `ElicitationFixtures`, so no new function stands alone at file scope, as the Swift immutability rule asks) with `bufferedCadence`, `usage`, `allowOption`, `rejectOption`, `immediateModel()`, `coalescingModel(clock:)` and `permissionRequest(title:)`; and `extension [ContentBlock] { var joinedText }`. Call sites now read `entry.content.joinedText`.

    Kept on purpose: ChunkCoalescerTests keeps its own `testCadence`. It tests ChunkCoalescer, not SessionModel, and it is a constant, not a helper. The shared names are namespaced because DecliningClientTests and SessionStateTests (outside Model/) have file-private `allowOption`, `permissionRequest`, `contextWindowSize` and `usedTokens`; a module-level name of the same spelling can make an ambiguous reference.

    Tool note: the `files` tool `edit file` with `replace_all: true` made only one replacement for each call here. Write the whole file, or give each edit a unique context.

    TDD: this is a test-only refactor with no production change, so no RED step. The existing suites are the check.
  timestamp: 2026-10-03T16:16:44.334908+00:00
- actor: claude-code
  id: 01m418vfw0xbj8bj2477bbq1xm
  text: |-
    ### implement — changed
    - evidence: 6 files. New: Tests/FoundationModelsACPClientTests/Model/SessionModelFixtures.swift. Changed: Model/SessionModelStreamTests.swift, Model/SessionModelCoalescingTests.swift, Model/SessionModelPendingTests.swift, Model/SessionModelPromptTests.swift, Model/SessionModelFoldTests.swift. No production file changed. `swift build`: Build complete; only the accepted MLX warning "missing creator for mutated node". `swift test`: 393 tests in 33 suites passed, 0 failures. Finding in "Review Findings (2026-10-03 11:05)" flipped to `- [x]`. Not committed.
    - next: /review
  timestamp: 2026-10-03T16:16:46.464777+00:00
- actor: claude-code
  id: 01m4190br3wtdfz4rypfq84a4s
  text: |-
    ### test — green (iteration 2, shared test fixtures)
    - evidence: swift build ok; swift test 393 tests in 33 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests ok; swift test --package-path IntegrationTests 103 tests in 14 suites passed, 0 failed, 0 skipped. Only warning: mlx-swift_Cmlx.bundle "missing creator for mutated node" (accepted MLX warning).
    - next: review
  timestamp: 2026-10-03T16:19:26.083211+00:00
- actor: claude-code
  id: 01m4190y5pkmdqc3dw6sb15m50
  text: |-
    ### commit — changed (iteration 2)
    - evidence: test(model): share SessionModel test fixtures. 8 files (SessionModelFixtures.swift new; 5 Model test files changed; task files in .kanban). Tests: swift test 393/393, IntegrationTests 103/103.
    - next: review
  timestamp: 2026-10-03T16:19:44.950517+00:00
depends_on:
- 01M3YRC0ERS5FADQYB965X5KJR
- 01M3YR18MVWMMHJGQ69PFCG77P
position_column: doing
position_ordinal: '80'
title: 'Model: SessionModel stream attachment, replay, missed updates, and close'
---
## What
Add the stream life of `SessionModel` in `Sources/FoundationModelsACPClient/Model/SessionModel+Stream.swift`. All of it is internal; only `ConnectionModel` calls it. The UI never subscribes itself.

Upstream API (foundationmodelsacp-c7, task ^1heg5df): `connection.subscribe(to: SessionId) -> SessionUpdateSubscription` with `updates: AsyncStream<SessionUpdate>` and `missedUpdates: Bool`. The first subscriber takes the buffer and the mark; then both are cleared. Use the final names from gate task 81s5j74.

- [x] `attach(_ subscription: SessionUpdateSubscription)`: starts one `@MainActor` task that calls `apply` for each update in order. `subscription.missedUpdates == true` sets public `hasMissedUpdates = true`.
- [x] Replay: `beginReplay(replayFrom: ReplayFrom?)` sets `isReplaying = true` before the `session/resume` request. If this model already has a transcript (resume of an open session), it first calls the engine `reset()` and clears `transcript` and the last-value state, because a replayed `*_chunk` appends again and doubles the text. `endReplay(succeeded: Bool)` sets `isReplaying = false`. A successful replay with `replayFrom == .start` gives the full retained history, so it sets `hasMissedUpdates = false`; any other result keeps the flag.
- [x] Public `history: SessionHistory` with `.live` and `.retained(replayFrom: ReplayFrom)`. It is a client-side value: take `replayFrom` from the `ResumeSessionRequest` that was sent (the response has no history field). A request with `replayFrom == nil` keeps `.live`.
- [x] `markClosed()`: calls `flushPendingChunks()`, cancels the stream task, finishes the `updateTap()` streams, calls `cancelAllPending()` (task pfcg77p), sets `isClosed = true`. After close, `apply` changes nothing.

## Acceptance Criteria
- [x] Updates on the attached subscription land in order in the model.
- [x] `missedUpdates == true` gives `hasMissedUpdates == true`; a later successful `.start` replay clears it.
- [x] A second replay into a model that has a transcript gives the same transcript as one replay (no doubled chunk text), and the entry objects are new.
- [x] `isReplaying` is true between `beginReplay` and `endReplay`, and false after a failure.
- [x] After `markClosed()`, `isClosed == true`, no pending item stays, the tap stream ends, and new updates change nothing.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift`: a hand-made subscription; overflow flag set and cleared by a `.start` replay; replay flags and `history`; double-replay test with chunk updates; close stops the fold, ends the tap, cancels the stream task, and cancels a pending permission.
- [x] `swift test --filter SessionModelStreamTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-10-03 11:05)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift:77` `reuse/reuse` — Function `joinedText()` is an exact duplicate of an existing function in SessionModelCoalescingTests.swift. The author should have searched for and reused the existing implementation instead of duplicating it. Extract `joinedText()` to a shared test utilities module or file (e.g., SessionModelTestHelpers.swift) and import it in both test files.
