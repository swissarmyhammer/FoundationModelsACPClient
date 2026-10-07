---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4b7akafb13pkns5yrnty3yt
  text: |-
    Research:
    - `ClientSideConnection.sessionCancel` (FoundationModelsACP) only sends the notification. It does not cancel the inbound `session/request_permission` handler tasks. Thus over the wire, a pending permission stays suspended after `session/cancel` until the model resolves it.
    - `ScriptedStubAgent.prompt` sends `permissionRequest` and discards the response. The wire test needs a record of the outcome: add `permissionOutcomes` to the stub and to `ConnectedModel`.
    - `FakeSessionRequestSender.cancel` cannot fail now. Add a way to make it throw (`failCancels(with:)`).
    - `ConnectionError` is Hashable, so `#expect(throws: ConnectionError.closed)` works.
    - The session-scoped elicitations stay pending already; `cancelKeepsPendingElicitations` is a guard test for the decision and passes before the change.
  timestamp: 2026-10-07T13:02:28.687528+00:00
- actor: claude-code
  id: 01m4b7hr4038bmat1k8k3sy0gh
  text: |-
    Implementation landed (TDD).
    - RED: `cancelAnswersEachPendingPermissionWithCancelled`, `aCancelThatFailsToSendStillCancelsThePermissions` and `cancelSendsTheCancelledOutcomeToTheAgent` failed at `pendingPermissions.isEmpty`. `cancelKeepsPendingElicitations` passed before the change, because it guards the elicitation decision; it did not fail first.
    - Each test uses `try #require(pendingPermissions.isEmpty)` before it awaits the permission task, so a regression fails at once and does not wait until the 1-minute suite time limit.
    - GREEN: `SessionModel.cancel(meta:)` calls `permissions.cancelAll()` before `requestSender.cancel(...)`. Doc comments of `cancel(meta:)`, `pendingPermissions`, `awaitPermissionDecision(for:)` and the file headers are updated. The old bullet on `awaitPermissionDecision(for:)` said the connection cancels the task "when the turn gets cancelled". That was not true, so the bullet is corrected.
    - Only production caller: `TurnRunner` (Ctrl-C). The CLI declines each permission at once, so nothing changes there.
    - Test support: `FakeSessionRequestSender.failCancels(with:)`, `ScriptedStubAgent.permissionOutcomes`, `ConnectedModel.permissionOutcomes`.
    - Found during the work: SwiftPM shows `warning: missing creator for mutated node ... mlx-swift_Cmlx.bundle` again. This is a dependency build warning, not a warning from this change. It is recorded as the new task ^9r2wsag.

    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACPClient/Model/SessionModel+Prompt.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift, Tests/FoundationModelsACPClientTests/Model/ModelClientTests.swift, Tests/FoundationModelsACPClientTests/Model/FakeSessionRequestSender.swift, Tests/FoundationModelsACPClientTests/Model/ConnectedModel.swift, Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift. `swift test --filter "SessionModelPendingTests|ModelClientTests"`: 29 tests passed. `swift test`: 531 tests in 45 suites passed, 0 failures. One SwiftPM build warning from the mlx-swift dependency (see ^9r2wsag).
    - next: /review
  timestamp: 2026-10-07T13:06:22.976315+00:00
- actor: claude-code
  id: 01m4b7t0s0tteqt3y8vtmv438h
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (46d3c78): 0 findings, 0 confirmed, 0 refuted; 7 files reviewed, 0 failed. No prior Review Findings sections.
    - next: task moved to done.
  timestamp: 2026-10-07T13:10:53.984801+00:00
- actor: claude-code
  id: 01m4b7t9p68ej69npqy5bc6jm0
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 7 files
    - test: green — swift test, 531 passed, 0 failed, 0 skipped
    - commit: 46d3c78
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-10-07T13:11:03.110045+00:00
position_column: done
position_ordinal: d880
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

- [x] After `cancel(meta:)`, `pendingPermissions` is empty.
- [x] Each suspended `awaitPermissionDecision(for:)` returns the `cancelled` outcome.
- [x] Over a real connection, the agent gets the `cancelled` outcome for each pending `session/request_permission`.
- [x] Pending session-scoped elicitations stay pending.
- [x] When the notification send throws, the permissions are still cancelled and the call throws the error.

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

- [x] Write the four failing tests.
- [x] Cancel the pending permissions in `cancel(meta:)`, before the notification.
- [x] Update the doc comments with the spec rule and the elicitation decision.
