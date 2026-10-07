---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4b7zm71z1b1gqfzag2qbv9m
  text: |-
    Research:
    - `ClientSideConnection.close()` goes to `Connection.shutDown(reason: .closedLocally)`. It cancels the read task. The read loop reads `NDJSONCodec.frames(from: transport.bytes)`; the cancel of that stream cancels the inner task that iterates `transport.bytes`, so the `onTermination` of the transport byte stream runs. `AgentProcess` tears down in that `onTermination`. If the inner task did not start its loop yet, the end comes a short time later, so the transport test waits for the end with `waitUntil` (it yields, no sleep).
    - `closed` comes only after each inbound handler ended. A request-scoped elicitation handler ends when its task is cancelled (the current `agentEnd.close()` test shows this), so `disconnect()` does not hang on it.
    - `connectionDidClose` has the guard `closed === connection`, so the second call from the close-wait task of `connect(over:)` changes nothing.
    - Plan: the five tests of the card go in ConnectionModelTests. The acceptance criterion for request-scoped elicitations gets one more test in ConnectionModelElicitationTests, because its `LoginHarness` is private to that file.
  timestamp: 2026-10-07T13:13:57.729896+00:00
- actor: claude-code
  id: 01m4b8amasj47pg8vrek0pffs9
  text: |-
    Implementation landed (TDD: the new tests failed first, with "value of type 'ConnectionModel' has no member 'disconnect'").
    - `ConnectionModel.disconnect()` keeps the open connection, calls `close()`, waits for `closed`, then calls `connectionDidClose`. The doc comment tells that no `session/close` goes out, and that the end of the byte stream ends an `AgentProcess`. The `connect(over:)` doc now names `disconnect()`.
    - The five tests of the card are in ConnectionModelTests. `EndRecordingTransport` records the `onTermination` of its byte stream. The test waits for it with `waitUntil` (no sleep), because the inner frames task of the connection can start its read after the close.
    - One more test, `aDisconnectByTheHostCancelsEachRequestScopedElicitation`, is in ConnectionModelElicitationTests for the request-scoped elicitation criterion. It shares one private helper with the agent-side close test, so the two bodies are not copies.
    - Discovery: when `disconnect()` returns, the state is final at once. It is `.disconnected`, or `.failed` when a read failure came first. A `connect(over:)` that starts during the wait makes the guard skip the record.

    ### implement — changed
    - evidence: Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelTests.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelElicitationTests.swift. `swift test --filter "ConnectionModelTests|ConnectionModelElicitationTests"`: 31 tests in 2 suites passed. `swift test`: 537 tests in 45 suites passed, 0 failures, 0 warnings (the accepted MLX "missing creator" warning is excluded).
    - next: /review
  timestamp: 2026-10-07T13:19:58.297627+00:00
position_column: doing
position_ordinal: '80'
title: 'Model: ConnectionModel.disconnect() closes the connection from the client side and ends the open sessions'
---
## What

A host that holds only a `ConnectionModel` cannot close the agent connection: `ConnectionModel.connection` (`Sources/FoundationModelsACPClient/Model/ConnectionModel.swift:65`) is `private(set)`, and the model has no close method. `connect(over:...)` returns the `ClientSideConnection`, but AgentViewKit binds only to the model. Now the in-process helper of the kit closes the connection from the agent side.

What exists:

- `ClientSideConnection.close() async` (FoundationModelsACP `Connection/ClientSideConnection.swift:375`) closes the connection. `closed` then gives `ConnectionCloseReason.closedLocally`.
- `ConnectionState(closedBecause:)` (`Sources/FoundationModelsACPClient/Model/ConnectionState.swift:29`) maps `.closedLocally` to `.disconnected`.
- `connect(over:...)` starts a task that waits for `opened.closed` and calls `connectionDidClose(_:because:)` (`ConnectionModel.swift:198`). That method sets `state`, stops the request watch (it cancels each pending request-scoped elicitation), and closes each open session model (each pending permission and session elicitation answers cancelled).

The name is `disconnect()`, not `close()`, because `ConnectionModel.close(_ session:)` (`ConnectionModel+Sessions.swift:268`) already closes one session.

1. In `ConnectionModel.swift`, add `public func disconnect() async`:
   - With no open connection, return at once and change nothing.
   - Else keep the connection, call `await connection.close()`, then `await connection.closed`, then call `connectionDidClose(connection, because: reason)`. That method has a guard (`closed === connection`), so the second call from the waiting task changes nothing.
   - The call returns only after `state == .disconnected` and `openSessions` is empty, so a host can read the state at once.
2. Document that `disconnect()` does not send `session/close` for each session: the agent frees them when the connection ends. A host that wants a clean close per session calls `close(_:)` first.
3. Document that for an `AgentProcess` transport, the end of the transport stream ends the process (`AgentProcess` tears down when the stream terminates). Check this in the test with a fake transport that records its end.
4. A later `connect(over:...)` works as now.

## Acceptance Criteria

- [ ] After `await model.disconnect()`, `state == .disconnected` and `openSessions` is empty.
- [ ] Each open session model has `isClosed == true`, and its pending permissions answer cancelled.
- [ ] Pending request-scoped elicitations of the model answer cancel.
- [ ] The transport of the connection is closed.
- [ ] A second `disconnect()`, and a `disconnect()` with no connection, change nothing and do not hang.
- [ ] `connect(over:)` after `disconnect()` gives a new connected model state.

## Tests

- Add tests to `Tests/FoundationModelsACPClientTests/Model/ConnectionModelTests.swift`, over `InMemoryTransport.pair()` with `ScriptedStubAgent`, and `ConnectedModel` (`Tests/FoundationModelsACPClientTests/Model/ConnectedModel.swift`). No sleeps.
  - `disconnectSetsDisconnectedAndClosesOpenSessions`
  - `disconnectCancelsPendingPermissions`
  - `disconnectClosesTheTransport`
  - `disconnectTwiceOrWithNoConnectionChangesNothing`
  - `connectAfterDisconnectWorks`
- Command: `swift test --filter ConnectionModelTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [x] Write the five failing tests.
- [x] Add `disconnect()`, and wait for `closed` before it returns.
- [x] Document the session and the `AgentProcess` behavior.
