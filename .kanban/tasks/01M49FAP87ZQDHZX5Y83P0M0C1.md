---
assignees:
- claude-code
depends_on:
- 01M49FA5BK7YA0BJ57PQCDQCM3
position_column: todo
position_ordinal: '8580'
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

- [ ] `await session.selectPermission(id, option:)` returns only after the response frame of that request is written to the transport.
- [ ] A prompt that the caller sends after that `await` goes on the wire after the permission response, in 100 of 100 runs, with no sleeps.
- [ ] `await session.cancelPermission(id)` has the same order guarantee, with the `cancelled` outcome.
- [ ] A call with an unknown or already resolved id returns at once.
- [ ] When the connection closes before the write, the call returns (through `onDiscard`) and does not hang.
- [ ] Each existing test passes with the `await` forms, and `swift build` gives no new warning.

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

- [ ] Write the four failing tests in `PermissionReplyOrderTests.swift`.
- [ ] Add the "written" waiters and `awaitPermissionDecision(for:afterResponse:)`.
- [ ] Make `selectPermission` and `cancelPermission` async, and resume the waiters on close.
- [ ] Register `work` and `onDiscard` in `ModelClient.requestPermission(_:)`.
- [ ] Add `await` at the existing call sites.
