---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4bb346k5rkwesrs41fzx20w
  text: |-
    Research (implement):
    - `ClientSideConnection.afterRespondingToCurrentRequest(_:onDiscard:)` is a sync method on a final Sendable class. It reads the task-local `Connection.currentResponseHooks`, so it must run on the dispatch task of the request. The main-actor hop of `SessionModel.awaitPermissionDecision` stays on the same task, so a `@MainActor` closure that the model calls after the decision finds the hooks.
    - `completeInbound` returns false when the connection is closed; then the hooks are discarded and `onDiscard` runs. `ClientSideConnection.close()` from inside a handler sets the closed flag before the handler returns, so a wrapping `Client` that closes the connection after the router returns gives a deterministic "connection closes before the write" test.
    - `SessionModel.cancel(meta:)` calls `permissions.cancelAll()`; that resolves only requests that no caller resolved, so no "written" waiter is attached to them. `markClosed()` calls `cancelAllPending()`.
    - Frame order on the agent side: wrap the agent end in `FrameTeeTransport` (AcpClientCore). Its forwarding task records inbound lines in wire order, before the agent read loop sees them. A record from the agent handlers would race, because the response and the prompt are handled on different tasks.
    - Plan: a small main-actor `ResponseWriteWaiters` (KeyedWaiters<UUID, Void> plus a state per id: expected / written) owned by SessionModel. Only ids that `selectPermission`/`cancelPermission` resolved are tracked, so a signal for an id that nobody waits on leaves no state.
  timestamp: 2026-10-07T14:08:18.131111+00:00
- actor: claude-code
  id: 01m4bdq2qmxwd7j9wx8ct11vaa
  text: |-
    Implementation landed (TDD).
    - RED: the four card tests ran against the old sync API. Three failed for the expected reason: both 100-round order tests (a `session/prompt` frame came before the permission response), and the close test (`didCloseTheConnection` was false, because the old call returned before the handler resumed). `selectPermissionWithAnUnknownIdReturnsAtOnce` passed in RED, because the old call also returns at once. It stays as a guard for the new wait path.
    - New `ResponseWriteWaiters` (main actor): a `KeyedWaiters<UUID, Void>` plus a `Progress` enum per id (`expected` / `written`). `selectPermission`/`cancelPermission` mark the id expected after a resolve that removed a request, and then wait. A signal for an id that no caller expects changes nothing, so a cancel of the turn or a task cancel leaves no state.
    - `awaitPermissionDecision(for:afterResponse:)`: with `nil`, the model signals at once. Otherwise it gives the closure a `@Sendable` signal that hops to the main actor through one short `Task` (`onDiscard` is sync and can run on the connection task).
    - `ModelClient.requestPermission` passes `{ signal in model.signalAfterCurrentResponse(signal) }`. The new `ConnectionModel.signalAfterCurrentResponse(_:)` calls `connection.afterRespondingToCurrentRequest({ signal() }, onDiscard: signal)`, or signals at once when no connection is open. It is a named method because a callback closure that branches must call a named method (swift/initialization rule).
    - `cancelAllPending()` calls `permissionWrites.resumeAll()`. `markClosed()` (thus `disconnect()` and each close) goes through `cancelAllPending()`.
    - Two extra tests: `selectPermissionReturnsWhenTheSessionCloses` (a decision that never signals; `markClosed` ends the wait) and `ResponseWriteWaitersTests.aSignalBeforeTheWaitEndsTheWaitAtOnce`. I watched each fail with a temporary probe: `resumeAll` removed, and a signal before the wait left as `expected`. Each failed on the 60 s time limit. Then I restored the code.
    - Dead end: my first version of the close test ran `selectPermission` in an unstructured `Task`. With the probe, the suite time limit could not cancel it, so `swift test` hung for 30 min. I had to kill it. The test now uses `async let`, so the time limit reaches the wait.
  timestamp: 2026-10-07T14:54:09.140667+00:00
- actor: claude-code
  id: 01m4bdq6gqe9gajejmk7marqcb
  text: |-
    ### implement — changed
    - evidence: 10 files — Sources/FoundationModelsACPClient/Model/ResponseWriteWaiters.swift (new), Sources/FoundationModelsACPClient/Model/SessionModel.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Sources/FoundationModelsACPClient/Model/ModelClient.swift, Tests/FoundationModelsACPClientTests/Model/PermissionReplyOrderTests.swift (new), Tests/FoundationModelsACPClientTests/Model/ResponseWriteWaitersTests.swift (new), Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift, Tests/FoundationModelsACPClientTests/Model/ModelClientTests.swift. `swift test --filter "PermissionReplyOrderTests|ResponseWriteWaitersTests"`: 6 passed. `swift build && swift test`: 555 tests in 48 suites passed, 0 failures, no warnings other than the accepted MLX "missing creator" warning.
    - next: /review (task stays in doing). Not committed.
  timestamp: 2026-10-07T14:54:13.015999+00:00
- actor: claude-code
  id: 01m4be9rawvg53zqrxdsct9tdw
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (98abca3); 1 finding (1 confirmed, 0 refuted) — Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift:146 swift/error-handling
    - next: implement the open item in "Review Findings (2026-10-07 09:57)"; the task stays in review
  timestamp: 2026-10-07T15:04:21.084647+00:00
- actor: claude-code
  id: 01m4bea2frth1k75mw73v67yjp
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 files
    - test: green — swift test, two runs, 555 passed, 0 failed, 0 skipped each, no hang
    - commit: 98abca3
    - review: findings — Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift:146
  timestamp: 2026-10-07T15:04:31.480515+00:00
- actor: claude-code
  id: 01m4befzkmj2kf6zfcpgt7xmb1
  text: |-
    Finding fixed: SessionModelPendingTests.twoOverlappingPermissionsResolveIndependently. Split `try await model.selectPermission(#require(...).id, ...)` into `let first = try #require(model.pendingPermissions.first)` and `await model.selectPermission(first.id, option: rejectOptionId)`. This is the same two-statement form that the file uses at its other call sites.
    Scan: I examined each `try await` in SessionModelPendingTests.swift, SessionModelStreamTests.swift, ModelClientTests.swift, PermissionReplyOrderTests.swift and ResponseWriteWaitersTests.swift. Each other `try await` calls a throwing method (waitUntil, startPermission, startElicitation, cancel(), requestPermission, prompt, newSession, initialize, call.value of a throwing Task). Each selectPermission/cancelPermission call in these files already uses a plain `await`. Only one line had the cause.
  timestamp: 2026-10-07T15:07:45.140799+00:00
- actor: claude-code
  id: 01m4beg13md1wrnz5cehkw2wj7
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift. `swift build && swift test`: 555 tests in 48 suites passed, 0 failures. The only warning is the accepted MLX "missing creator" warning (task zws9qzt).
    - next: /review (task stays in doing). Not committed.
  timestamp: 2026-10-07T15:07:46.676606+00:00
depends_on:
- 01M49FA5BK7YA0BJ57PQCDQCM3
position_column: doing
position_ordinal: '80'
title: 'Model: selectPermission and cancelPermission wait until the response frame is written'
---
## What

Now `SessionModel.selectPermission(_:option:)` and `cancelPermission(_:)` (`Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift:60` and `:72`) are synchronous. They resume the continuation of `awaitPermissionDecision(for:)` through `PendingRequestQueue.resolve(_:with:)`. Then `ModelClient.requestPermission(_:)` returns, and the connection writes the response frame later. Thus a `session/prompt` that the caller sends just after the call can go out before the permission response.

This task uses the API of FoundationModelsACP task **34m4s52**, which task ^qcdqcm3 brings into this package:

```swift
// ClientSideConnection
public func afterRespondingToCurrentRequest(
    _ work: @escaping @Sendable () async -> Void,
    onDiscard: @escaping @Sendable () -> Void
)
```

- `work` runs after the response frame is given to the transport.
- `onDiscard` runs exactly one time when `work` will never run, and never when `work` runs. It is synchronous.
- Outside an inbound request, `onDiscard` runs at once, before the method returns. It also runs for a late call, and when the connection closes before it writes the response.

Thus each path ends with exactly one of the two calls, and the model needs no special path for "no connection".

1. `Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift`:
   - Change the two methods to `public func selectPermission(_ id: PendingPermissionRequest.ID, option optionId: PermissionOptionId) async` and `public func cancelPermission(_ id: PendingPermissionRequest.ID) async`. Each resolves the request as now, then suspends until the "written" signal of that id arrives.
   - Do not keep sync forms with the same names: in an async context Swift prefers the async overload, so a sync call with no `await` does not compile. The kit is the only external caller.
   - Add a "written" waiter for each pending id, for example a `KeyedWaiters<UUID, Void>` (`Sources/FoundationModelsACPClient/KeyedWaiters.swift`). The waiter must accept a signal that arrives before the caller waits (keep a "signalled" set), because `onDiscard` can run before `selectPermission` suspends.
   - Change `awaitPermissionDecision(for:)` to `awaitPermissionDecision(for:afterResponse:)`. `afterResponse` is an optional closure `(_ signal: @escaping @Sendable () -> Void) -> Void`. The model calls it with the "written" signal of the id after the decision. When it is `nil` (a unit test with no `ModelClient`), the signal goes at once.
   - An unknown or already resolved id returns at once.
   - `cancelAllPending()` and `markClosed()` resume each "written" waiter, so no caller stays suspended.
2. `Sources/FoundationModelsACPClient/Model/ModelClient.swift`, `requestPermission(_:)`: after `awaitPermissionDecision` returns, and before the handler returns (on the same task, with no `Task {}`), call `connection.afterRespondingToCurrentRequest({ signal() }, onDiscard: { signal() })`. Both ends give the same signal: `onDiscard` means that no frame will be written, so the caller must not wait longer. When the model has no connection, call `signal()` at once.
3. Update the call sites to `await`: `Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift`, `Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift:483`, `Tests/FoundationModelsACPClientTests/Model/ModelClientTests.swift:96`. (This is a mechanical change.)

## Acceptance Criteria

- [x] `await session.selectPermission(id, option:)` returns only after the response frame of that request is written to the transport.
- [x] A prompt that the caller sends after that `await` goes on the wire after the permission response, in 100 of 100 runs, with no sleeps.
- [x] `await session.cancelPermission(id)` has the same order guarantee, with the `cancelled` outcome.
- [x] A call with an unknown or already resolved id returns at once.
- [x] When the connection closes before the write, the call returns (through `onDiscard`) and does not hang.
- [x] Each existing test passes with the `await` forms, and `swift build` gives no new warning.

## Tests

- Add `Tests/FoundationModelsACPClientTests/Model/PermissionReplyOrderTests.swift`. Use a real `ConnectionModel` over `InMemoryTransport.pair()`. On the agent side, record the order of the frames that arrive (a recording agent built on `ScriptedStubAgent`, or a tee of the agent end like `FrameTeeTransport`). No sleeps; wait with the existing `waitUntil` helper on observable state only.
  - `selectPermissionResponseIsWrittenBeforeTheNextPrompt` — loop 100 times: the agent sends `session/request_permission`; the test waits for `pendingPermissions.first`, calls `await selectPermission`, then calls `prompt`; the agent side sees the permission response before the `session/prompt` frame.
  - `cancelPermissionResponseIsWrittenBeforeTheNextPrompt` — the same with `cancelPermission`, 100 times.
  - `selectPermissionReturnsWhenTheConnectionClosesFirst`
  - `selectPermissionWithAnUnknownIdReturnsAtOnce`
- Command: `swift test --filter PermissionReplyOrderTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [x] Write the four failing tests in `PermissionReplyOrderTests.swift`.
- [x] Add the "written" waiters and `awaitPermissionDecision(for:afterResponse:)`.
- [x] Make `selectPermission` and `cancelPermission` async, and resume the waiters on close.
- [x] Register `work` and `onDiscard` in `ModelClient.requestPermission(_:)`.
- [x] Add `await` at the existing call sites.

## Review Findings (2026-10-07 09:57)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift:146` `swift/error-handling` — `try await` is used with `selectPermission(_:option:)`, which is declared as `async` (not `async throws`). The `try` keyword should only precede functions or expressions that can throw. If `#require` throws, the `try` should apply only to that macro call, not to the entire expression. Either split the expression into two statements: `let pending = try #require(model.pendingPermissions.first); await model.selectPermission(pending.id, option: rejectOptionId)` or write `await model.selectPermission(try #require(model.pendingPermissions.first).id, option: rejectOptionId)` so `try` applies only to the `#require` call.
