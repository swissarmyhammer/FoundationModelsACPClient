---
assignees:
- claude-code
depends_on:
- 01M3YR0FJ4Z55VAXKXQ3KAM7GW
position_column: todo
position_ordinal: '8580'
title: 'Model: SessionModel pending permissions and session-scoped elicitations'
---
## What
Move the pending-request state from `ACPSessionState` and `SwiftUIACPClient` into `SessionModel`. New file `Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift`. Reuse `PendingRequestStates.swift`, `PendingPermissionRequest.swift`, `PendingElicitation.swift` (adapt them; do not copy them). Add `PendingElicitation.requestId: RequestId?` (nil for session scope) for the request-scope task.

- [ ] `pendingPermissions: [PendingPermissionRequest]`, internal `awaitPermissionDecision(for:) async -> RequestPermissionResponse`, public `selectPermission(_ id:, option:)` and `cancelPermission(_ id:)`. Same continuation rules as now: one resume, task cancellation answers `cancelled`.
- [ ] `pendingElicitations: [PendingElicitation]` (session scope), internal `awaitElicitation(_:)`, public `acceptElicitation(_:content:)`, `declineElicitation(_:)`, `cancelElicitation(_:)`. Url-mode completion by `elicitationId` (internal `completeElicitation(elicitationId:) -> Bool`, true when it held the id).
- [ ] An elicitation with a `toolCallId` adds its id to `linkedElicitationIDs` of that tool-call entry, and the id is removed when it resolves. If the tool-call entry does not exist yet, keep the link in an unresolved map and apply it when that tool-call entry is added.
- [ ] `public func cancelAllPending()`: cancels every pending permission and elicitation. The stream task (ccdm82c) calls it from `markClosed()`.

## Acceptance Criteria
- [ ] Each resolution removes the item and resumes the continuation exactly one time.
- [ ] A tool-call entry shows its linked elicitation while it is pending, and not after, also when the elicitation arrives before the tool call.
- [ ] `cancelAllPending()` answers `cancelled` / `cancel` to every pending item.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift`: port the cases of `PermissionRequestTests.swift` and the session-scope cases of `ElicitationTests.swift` (reuse `ElicitationFixtures.swift`); add `toolCallLinkWhenToolCallExists`, `toolCallLinkWhenElicitationArrivesFirst`, and `cancelAllPendingAnswersEveryItem`.
- [ ] `swift test --filter SessionModelPendingTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.