---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m411gybq28y94f3wdr25fz1z
  text: |-
    Research (2026-10-03):
    - The continuation lifecycle (recordArrival, withTaskCancellationHandler + withCheckedContinuation, suspend, takeSuspended, noteCancellation, append/remove of the pending item) is written two times now: `ACPSessionState.awaitPermissionDecision` and `SwiftUIACPClient.createElicitation`. A third copy in SessionModel would be a duplication finding. Plan: put one generic `@MainActor @Observable final class PendingRequestQueue<Item, Response>` in PendingRequestStates.swift (it owns the items list and the states), and make all three owners use it. The old public API of ACPSessionState and SwiftUIACPClient stays the same.
    - The elicitation action objects (accept/decline/cancel) are private statics of SwiftUIACPClient. Move them to PendingElicitation.swift (`ElicitationResponseWire`) so SessionModel and SwiftUIACPClient share them.
    - `ElicitationFormMode.Scope` and `ElicitationUrlMode.Scope` are two distinct enums with the same two cases (`.session(ElicitationSessionScope)`, `.request(ElicitationRequestScope)`), no unknown case. `ElicitationSessionScope.toolCallId: ToolCallId?`; `ElicitationRequestScope.requestId: RequestId`. `CreateElicitationResponse` is a typealias of JSONValue.
    - A Swift extension in another file cannot read `private` stored members, so SessionModel.swift must hold the new stored properties (queues, unresolved link map), and `wireEntries` needs an internal getter for the tool-call lookup.
    - Link removal: the UI resolutions remove the link synchronously; the task-cancellation path and the cancelled-before-registration path remove it when `awaitElicitation` returns (a `defer`).
  timestamp: 2026-10-03T14:08:40.823811+00:00
- actor: claude-code
  id: 01m411ts59yd4y81fsh0ybb0wy
  text: |-
    Implementation landed (not committed):
    - `PendingRequestStates.swift`: new `@MainActor @Observable final class PendingRequestQueue<Item, Response>` (items + states; `awaitResponse(to:)`, `resolve(_:with:) -> Item?`, `cancel(_:) -> Item?`, `cancelAll()`). It is now the one owner of the continuation lifecycle.
    - `ACPSessionState` and `SwiftUIACPClient` use the queue. Their public API is the same (`pendingPermissionRequests` and `pendingElicitations` are now computed reads of the observable queue). The old copies of the lifecycle and the private elicitation action builders are deleted.
    - `PendingElicitation.swift`: `requestId: RequestId?`, `toolCallId: ToolCallId?`, one private `wireScope` that reads both mode scope enums; `ElicitationResponseWire` (internal) now holds the accept/decline/cancel action objects. `PendingPermissionRequest.swift`: `cancelledResponse`, `selectedResponse(_:)`.
    - `Model/SessionModel.swift`: stored `permissions`, `elicitations` queues and `unresolvedElicitationLinks`; `wireEntries` has an internal getter; `addEntry` calls `attachUnresolvedElicitationLinks(to:)`.
    - `Model/SessionModel+Pending.swift`: the API on the card.
    - Link removal design: UI resolutions (`accept`/`decline`/`cancel`/`complete`/`cancelAllPending`) remove the link synchronously. The task-cancellation path removes it when `awaitElicitation` returns (a `defer`), which also covers a cancellation before registration.
    - Out of scope, noted for ^bgewsw: `AcpClientCore/DecliningClient.swift` keeps its own private decline object (another module; `ElicitationResponseWire` is internal).
    - TDD: RED was the compile failure of the new test file (missing `pendingPermissions`, `selectPermission`, `requestId`, ...). GREEN: 17/17.
  timestamp: 2026-10-03T14:14:03.177411+00:00
- actor: claude-code
  id: 01m411tvhbh3e6xp472q1x5wgr
  text: |-
    ### implement — changed
    - evidence: `swift test --filter SessionModelPendingTests` -> 17 tests in 1 suite passed. `swift build` -> Build complete; only the permitted `SessionUpdateAggregator` deprecations and the accepted MLX warnings. `swift test` -> 328 tests in 29 suites passed, 0 failed. Files: Sources/FoundationModelsACPClient/{PendingRequestStates.swift, PendingElicitation.swift, PendingPermissionRequest.swift, ACPSessionState.swift, SwiftUIACPClient.swift, Model/SessionModel.swift, Model/SessionModel+Pending.swift (new)}, Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift (new).
    - next: /review
  timestamp: 2026-10-03T14:14:05.611061+00:00
- actor: claude-code
  id: 01m411v3h0peknj8h5gpksbtw3
  text: 'Correction to the comment "Implementation landed": the id "^bgewsw" in it is wrong. The `DecliningClient` decline object belongs to task ^hvqk65a (the task that moves DecliningClient). ModelClient routing is task ^cfh2wsw.'
  timestamp: 2026-10-03T14:14:13.792256+00:00
- actor: claude-code
  id: 01m41207qf85ntjf3zrqhg27d2
  text: |-
    ### test — green
    - evidence: swift build ok; swift test 328 tests in 29 suites passed; swift build --package-path IntegrationTests ok; swift test --package-path IntegrationTests 103 tests in 14 suites passed. 0 failures, 0 skipped.
    - warnings: only accepted ones (mlx-swift Cmlx bundle "missing creator" warning; SessionUpdateAggregator deprecations at ACPSessionState.swift).
    - next: review
  timestamp: 2026-10-03T14:17:01.935652+00:00
- actor: claude-code
  id: 01m4120mwv2qqxs385mtv0p23f
  text: |-
    ### commit — changed
    - evidence: feat(model): add pending permissions and elicitations to SessionModel; 12 files; swift test 328/328, IntegrationTests 103/103
    - next: review. Shared PendingRequestQueue now serves ACPSessionState, SwiftUIACPClient and SessionModel.
  timestamp: 2026-10-03T14:17:15.419986+00:00
- actor: claude-code
  id: 01m4128b0xcraydxq2zw0vt1xf
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 95788e8); 8 files reviewed, 4 .kanban files excluded by .reviewignore; counts: 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. The task had no earlier Review Findings sections.
    - next: none. The task is in done.
  timestamp: 2026-10-03T14:21:27.453989+00:00
- actor: claude-code
  id: 01m4128jjf6py4735w9tcgnm1z
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files (shared PendingRequestQueue, SessionModel+Pending.swift, 17 new tests)
    - test: green — swift test 328/328, IntegrationTests 103/103; only accepted warnings
    - commit: 95788e8 feat(model): add pending permissions and elicitations to SessionModel
    - review: clean — task moved to done
  timestamp: 2026-10-03T14:21:35.183343+00:00
depends_on:
- 01M3YR0FJ4Z55VAXKXQ3KAM7GW
position_column: done
position_ordinal: bd80
title: 'Model: SessionModel pending permissions and session-scoped elicitations'
---
## What
Move the pending-request state from `ACPSessionState` and `SwiftUIACPClient` into `SessionModel`. New file `Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift`. Reuse `PendingRequestStates.swift`, `PendingPermissionRequest.swift`, `PendingElicitation.swift` (adapt them; do not copy them). Add `PendingElicitation.requestId: RequestId?` (nil for session scope) for the request-scope task.

- [x] `pendingPermissions: [PendingPermissionRequest]`, internal `awaitPermissionDecision(for:) async -> RequestPermissionResponse`, public `selectPermission(_ id:, option:)` and `cancelPermission(_ id:)`. Same continuation rules as now: one resume, task cancellation answers `cancelled`.
- [x] `pendingElicitations: [PendingElicitation]` (session scope), internal `awaitElicitation(_:)`, public `acceptElicitation(_:content:)`, `declineElicitation(_:)`, `cancelElicitation(_:)`. Url-mode completion by `elicitationId` (internal `completeElicitation(elicitationId:) -> Bool`, true when it held the id).
- [x] An elicitation with a `toolCallId` adds its id to `linkedElicitationIDs` of that tool-call entry, and the id is removed when it resolves. If the tool-call entry does not exist yet, keep the link in an unresolved map and apply it when that tool-call entry is added.
- [x] `public func cancelAllPending()`: cancels every pending permission and elicitation. The stream task (ccdm82c) calls it from `markClosed()`.

## Acceptance Criteria
- [x] Each resolution removes the item and resumes the continuation exactly one time.
- [x] A tool-call entry shows its linked elicitation while it is pending, and not after, also when the elicitation arrives before the tool call.
- [x] `cancelAllPending()` answers `cancelled` / `cancel` to every pending item.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift`: port the cases of `PermissionRequestTests.swift` and the session-scope cases of `ElicitationTests.swift` (reuse `ElicitationFixtures.swift`); add `toolCallLinkWhenToolCallExists`, `toolCallLinkWhenElicitationArrivesFirst`, and `cancelAllPendingAnswersEveryItem`.
- [x] `swift test --filter SessionModelPendingTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.