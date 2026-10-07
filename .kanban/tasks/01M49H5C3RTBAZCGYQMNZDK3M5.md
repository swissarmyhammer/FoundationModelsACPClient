---
assignees:
- claude-code
position_column: todo
position_ordinal: 8a80
title: 'Model: SessionModel.cancel answers each pending permission request with the cancelled outcome (ACP MUST)'
---
## What

ACP v2 prompt lifecycle, Cancellation (https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#cancellation): when the client sends `session/cancel`, "The Client **MUST** respond to all pending `session/request_permission` requests with the `cancelled` outcome." The schema repeats the rule on `RequestPermissionOutcome.cancelled`.

Now `SessionModel.cancel(meta:)` (`Sources/FoundationModelsACPClient/Model/SessionModel+Prompt.swift:79`) only sends the notification. The pending permissions stay in `pendingPermissions` until the user answers them or the agent withdraws them. `cancelAllPending()` (`Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift:163`) runs only on close (`SessionModel+Stream.swift:254`). Thus the model breaks the spec, and AgentViewKit must clear the permission cards itself.

1. In `SessionModel+Prompt.swift`, `cancel(meta:)`: before the notification goes out, call `permissions.cancelAll()`, so each pending permission resolves with `PendingPermissionRequest.cancelledResponse` and leaves `pendingPermissions`.
2. Do not cancel the session-scoped elicitations. The spec gives no such rule for elicitations, and an elicitation can belong to work that is not the turn. Write this decision in the doc comment of `cancel(meta:)`.
3. A failed send of the notification (`ConnectionError`) still leaves the permissions cancelled: the user asked to stop the turn.
4. Update the doc comments of `cancel(meta:)` and of `pendingPermissions` (`SessionModel+Pending.swift:11`).

## Acceptance Criteria

- [ ] After `cancel(meta:)`, `pendingPermissions` is empty.
- [ ] Each suspended `awaitPermissionDecision(for:)` returns the `cancelled` outcome.
- [ ] Over a real connection, the agent gets the `cancelled` outcome for each pending `session/request_permission`.
- [ ] Pending session-scoped elicitations stay pending.
- [ ] When the notification send throws, the permissions are still cancelled and the call throws the error.

## Tests

- Add tests to `Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift`, with `FakeSessionRequestSender` (make its `cancel` throw for the failure case). No sleeps.
  - `cancelAnswersEachPendingPermissionWithCancelled`
  - `cancelKeepsPendingElicitations`
  - `aCancelThatFailsToSendStillCancelsThePermissions`
- Add `cancelSendsTheCancelledOutcomeToTheAgent` to `Tests/FoundationModelsACPClientTests/Model/ModelClientTests.swift`, over `InMemoryTransport.pair()` with a `ScriptedStubAgent` that sends one permission request and records the outcome.
- Command: `swift test --filter SessionModelPendingTests`, `swift test --filter ModelClientTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [ ] Write the four failing tests.
- [ ] Cancel the pending permissions in `cancel(meta:)`, before the notification.
- [ ] Update the doc comments with the spec rule and the elicitation decision.
