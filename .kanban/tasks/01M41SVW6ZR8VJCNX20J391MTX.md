---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m41w7r18j1nawabhwjj4dz7d
  text: |-
    Research (implement):
    - `resumeSession(_:)` reads `openSessions[request.sessionId]` before its first suspension, then `replay(...)` calls `beginReplay`, `watchResumeStarts` and `connection.resumeSession`. Two calls that overlap thus make two models (session not open yet) or share one replay state (session open).
    - Upstream `Connection.request` (FoundationModelsACP f72b8ad) handles a caller cancel in `cancelOutbound(id:)` -> `fail(id:with:)`. That records `.finished` and the `requestFinished` marker BEFORE the caller gets `CancellationError`. So when resumes of one session run one after the other, the next replay never sees the start of a cancelled earlier request.
    - Deterministic test entry: the toolchain is Swift 6.4 and the platform is macOS 27, so `Task.immediate` runs the second call on the main actor up to its first suspension before the test continues. Before the fix that suspension is after `beginReplay`; after the fix it is the wait for the turn. No sleep is necessary.
    - Choice: serialize per session id with a small main-actor turn queue (`KeyedTurnQueue`) held by `ConnectionModel`. A second call waits until the first call returned or threw, then runs the whole body again (it then finds the model that the first call registered). A waiting call that its task cancels leaves the queue at once and throws `CancellationError`, and sends nothing.
  timestamp: 2026-10-03T21:55:30.984327+00:00
- actor: claude-code
  id: 01m41y9d8gjpkg233b7ge6hn2b
  text: |-
    Implementation notes:
    - New `KeyedTurnQueue<Key>` (main actor, `Model/KeyedTurnQueue.swift`). `ConnectionModel.resumeTurns` holds one queue keyed by session id. `resumeSession(_:)` checks the capability, then runs the old body (now the private `resumeInTurn(_:)`) through the queue. Resumes of different sessions do not wait for each other.
    - A waiting call obeys the cancel of its task: `withTaskCancellationHandler` hops to the main actor, takes the waiter out of the queue and throws `CancellationError`. The resume then sends nothing.
    - RED evidence: before the fix, the concurrent test gave two models and the interleaved text `HelHellolo`; the cancel test gave `isReplaying == false` and `history == .live` while the second request was still held. The cancel-while-waiting test with the first (not cancel-aware) wait never ended: Swift Testing `.timeLimit` does not stop a wait on `Task.value`, so `swift test` hung until I killed it. The next agent must not run a hanging RED like that again; it costs the full shell timeout.
    - `Task.immediate { @MainActor in ... }` (fixture `startResumeNow(on:)`) is the event that puts the second call inside `resumeSession(_:)` before the test continues. No sleep.
    - No `ARCHITECTURE.md` exists, so no architecture doc change.

    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPClient/Model/KeyedTurnQueue.swift (new), Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift (3 new tests). `swift build` OK; `swift test` 511 tests in 41 suites passed; `swift test --package-path IntegrationTests` 103 tests in 14 suites passed; only the accepted MLX "missing creator" warning and the permitted `SessionUpdateAggregator` deprecation warnings.
    - next: /review
  timestamp: 2026-10-03T22:31:22.640570+00:00
- actor: claude-code
  id: 01m42333h8hk3xxtpajy21b064
  text: |-
    ### test — green
    - evidence: swift build clean. swift test: 511 tests in 41 suites passed. swift test --package-path IntegrationTests: 103 tests in 14 suites passed. swift test --filter ConnectionModelSessionTests: 10 of 10 runs passed.
    - warnings: only the accepted ones (mlx-swift missing creator for mutated node, SessionUpdateAggregator deprecation). No skipped tests.
    - found: in the first 10 runs, 9 passed and 1 failed. The failed test was aResumeAfterACancelledStartedResumeEndsItsReplayOnlyAtItsOwnMarker (expectation session.isReplaying was false).
    - cause: UpdateGate in ScriptedStubAgent.swift used an AsyncStream. A cancel of a task that waits on the stream ends the whole stream. The stub agent cancelled the first resume handler, and this opened the gate for the second resume handler. The agent answer then came before the test check.
    - fix: UpdateGate now uses a Mutex and continuations. Only open() lets a waiter through. File: Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift. Source code of the change is not modified.
    - check: the single test ran about 196 times after the fix with 0 failures. Before the fix it failed 1 time in about 100 to 150 runs.
    - next: review.
  timestamp: 2026-10-03T23:55:18.952268+00:00
- actor: claude-code
  id: 01m4233kbtqnbd8y46hfdqdnrx
  text: |-
    ### commit — changed
    - evidence: one local commit, subject "fix(model): run the resumes of one session one after the other". It holds the source, the tests, and the .kanban files. The sha is in the final report of the commit step.
    - next: review. No push was done.
  timestamp: 2026-10-03T23:55:35.162886+00:00
- actor: claude-code
  id: 01m4239q1n5q8w0ys31wh7xw6n
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (c074d6d); 1 finding (1 confirmed, 0 refuted) — Sources/FoundationModelsACPClient/Model/KeyedTurnQueue.swift:13 (duplication/duplication)
    - next: Extract the shared keyed continuation queue so that KeyedTurnQueue and PendingRequestQueue use one implementation, then review again.
  timestamp: 2026-10-03T23:58:55.541272+00:00
- actor: claude-code
  id: 01m423a028xhfe29kkmn34ydct
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 4 files (KeyedTurnQueue.swift new, ConnectionModel.swift, ConnectionModel+Sessions.swift, ConnectionModelSessionTests.swift)
    - test: green — swift test 511/511, IntegrationTests 103/103, ConnectionModelSessionTests 10/10 runs after the UpdateGate fix
    - commit: c074d6d fix(model): run the resumes of one session one after the other
    - review: findings — Sources/FoundationModelsACPClient/Model/KeyedTurnQueue.swift:13 (duplication/duplication)
  timestamp: 2026-10-03T23:59:04.776253+00:00
- actor: claude-code
  id: 01m423e92ge3jkj8jnwbdr7q88
  text: |-
    Research (implement, finding KeyedTurnQueue duplication/duplication):
    - `PendingRequestQueue` (PendingRequestStates.swift) and `KeyedTurnQueue` both keep main-actor continuations by key, add a `withTaskCancellationHandler` whose handler hops to the main actor with `Task { @MainActor [weak self] in ... }`, and resume each continuation one time. The differences: the key type (UUID item id vs. SessionId), the resume value (Response vs. turn or cancel), the value for a cancelled caller, the step when the caller is in the queue (append the item to `items`), and the step when a cancel takes the caller out (remove the item from `items`).
    - The `cancelledBeforeRegistration` state of `PendingRequestStates` cannot occur on Swift 6.4: `awaitResponse` is main-actor, and `recordArrival`, `withTaskCancellationHandler` and the `withCheckedContinuation` body run in one main-actor job with no suspension. The cancel handler only starts a Task, which runs after the body registered. The `Task.isCancelled` check of `KeyedTurnQueue.enqueue` covers the one real case (a task that was cancelled before the call).
    - No test refers to `PendingRequestStates`.
    - Plan: one generic main-actor core `KeyedWaiters<Key, Value>` (new file Sources/FoundationModelsACPClient/KeyedWaiters.swift) with `wait(for:onSuspend:onCancel:)` and `resumeFirst(of:with:)`. `PendingRequestQueue` uses it with Key = UUID, Value = Response. `KeyedTurnQueue` uses it with Key = its key, Value = a turn enum, plus a set of running keys. `PendingRequestStates` is deleted.
  timestamp: 2026-10-04T00:01:25.072092+00:00
- actor: claude-code
  id: 01m423qdbyz105qwj7838rq5gt
  text: |-
    Implementation notes (finding KeyedTurnQueue duplication/duplication):
    - New shared core `KeyedWaiters<Key, Value>` (Sources/FoundationModelsACPClient/KeyedWaiters.swift): main actor, callers wait by key in call order, `wait(for:onSuspend:onCancel:)` and `resumeFirst(of:with:)`. The task-cancel handler and the `Task.isCancelled` check now exist one time.
    - `PendingRequestQueue` now uses it with Key = item id (UUID) and Value = Response. The struct `PendingRequestStates` is deleted, and its file is renamed (git mv) to PendingRequestQueue.swift. A task cancel removes the item from `items` through the `onCancel` step, in the same main-actor job as before.
    - `KeyedTurnQueue` now uses it with a private `Turn` enum (`granted`, `cancelled`) and a `runningKeys` set. Its own Waiter, waiter dictionary, id counter, enqueue and cancel steps are deleted.
    - One behavior detail: a pending request whose task was cancelled before `awaitResponse` now answers cancelled at once and never shows in `items` (before, it showed for one main-actor job). No test depends on the old detail.
    - RED: KeyedWaitersTests.swift (4 tests) failed to compile with "cannot find type 'KeyedWaiters' in scope". GREEN: 4 of 4 passed.

    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPClient/KeyedWaiters.swift (new), Sources/FoundationModelsACPClient/PendingRequestQueue.swift (renamed from PendingRequestStates.swift, PendingRequestStates deleted), Sources/FoundationModelsACPClient/Model/KeyedTurnQueue.swift, Tests/FoundationModelsACPClientTests/KeyedWaitersTests.swift (new, 4 tests). `swift build` OK; `swift test` 515 tests in 41 suites passed; `swift test --package-path IntegrationTests` 103 tests in 14 suites passed; only the accepted MLX "missing creator" warning and the permitted `SessionUpdateAggregator` deprecation warnings. Finding flipped to [x].
    - next: /review
  timestamp: 2026-10-04T00:06:24.382417+00:00
- actor: claude-code
  id: 01m423vt07gd0p7re0dgwecga0
  text: |-
    ### test - green
    - evidence: swift build - complete, only the accepted mlx "missing creator for mutated node" warning. swift test - 515 tests in 41 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests - 103 tests in 14 suites passed, 0 failed, 0 skipped. swift test --filter "ConnectionModelSessionTests|KeyedWaitersTests|Pending" - 67 tests in 7 suites passed, run 1 time.
    - note: the request asked for 10 runs of the filter. The test rules forbid a test run in a loop and forbid a rerun with no code change. So the filter ran 1 time (1 of 1 passed). No 10-run count exists.
    - next: review
  timestamp: 2026-10-04T00:08:48.391142+00:00
- actor: claude-code
  id: 01m423w2sr2b3dg1xh5d14smrk
  text: |-
    ### commit — changed
    - evidence: one local commit, refactor(model): share one keyed waiter core between the pending and turn queues
    - next: review
  timestamp: 2026-10-04T00:08:57.400394+00:00
position_column: doing
position_ordinal: '8180'
title: 'Model: two concurrent resumeSession calls of one session share one replay state'
---
## What
Found during ^6np8vdv (2026-10-03). `ConnectionModel.resumeSession(_:)` does not serialize the `session/resume` requests of one session. When a caller starts a second resume of an open session while the first resume of the same session is still in flight:
- the second `beginReplay(replayFrom:)` resets the transcript of the shared model during the first replay;
- the outgoing-request subscription of the second replay replays the start of the first request, so the marker of the first request can end the second replay;
- the failure path of the first call (`endRunningReplayAsFailure()`) ends the replay of the second call.

The fix of ^6np8vdv (match the marker by the id of a request that started during the replay) is exact only for resumes of one session that run one after the other.

## Proposed approach
Serialize `resumeSession(_:)` per session id in `ConnectionModel`: a second call for the same session waits until the first call returned or threw, then runs. For a session id that is not open yet, the second call then finds the model that the first call registered.

## Acceptance Criteria
- [x] Two concurrent `resumeSession` calls of one session give one model, and each replay ends only at the marker of its own request.
- [x] A cancelled first call does not end the replay of the second call.

## Tests
- [x] A test in `Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift` that starts two resumes of one session at the same time with a held answer gate, and checks the replay state with events (gates, HoldableTaskExecutor), never fixed sleeps.

## Workflow
- Use `/tdd`.

## Review Findings (2026-10-03 18:55)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPClient/Model/KeyedTurnQueue.swift:13` `duplication/duplication` — KeyedTurnQueue duplicates the queue-by-key pattern from the existing PendingRequestQueue. Both implement nearly identical continuation-based synchronization: a Waiter structure, a waiters dictionary keyed by identifier, an ID counter, and operations to enqueue, cancel, and pass turns. Maintaining two copies risks drift — a fix in one may not reach the other. Extract a generic queue base class or shared helper parameterized by key type. Have both KeyedTurnQueue (for session resume ordering) and PendingRequestQueue (for elicitation ordering) delegate to this shared implementation instead of repeating the continuation logic.
