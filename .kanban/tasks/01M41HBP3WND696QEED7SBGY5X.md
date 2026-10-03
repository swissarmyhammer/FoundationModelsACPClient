---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m41htjj8tabmj7b2av1s0zdt
  text: |-
    Research done.
    - The real wire gives no event between the moment the `session/new` answer resolves and the moment `newSession` continues on the main actor. Both that continuation and the close task of `connect(over:)` hop to the main actor; the order of the two hops is not under test control. A test that only closes the agent end after the answer passes or fails by schedule, so it is not a proof.
    - `Connection.request` emits `OutgoingRequestEvent.finished(id:)` on the connection actor when it takes the answer, before the caller continues. After that, the rest of the call (`RoleDispatch.call`, `callResult`, `ClientSideConnection.newSession`) is nonisolated. Under `withTaskExecutorPreference`, that nonisolated part runs on the preferred executor.
    - Plan for the test: a test executor whose serial queue the test can hold. Hold it after the agent got `session/new`, open the agent answer gate, wait for `finished`, close the agent end, wait until `state == .disconnected`, then release. The continuation then always runs after `connectionDidClose`.
    - `AgentSideConnection.close()` does not close the transport; the test must close the agent end (`InMemoryTransport.close()`), so `ConnectedModel` must expose `agentEnd`.
    - `ScriptedStubAgent` needs a `newSessionGate`, the same shape as `loginGate`.
    - `resumeSession(_:)` does not exist yet in `ConnectionModel+Sessions.swift`; task ^6np8vdv adds it. This task does not touch it. The second subtask stays open for ^6np8vdv; the new check is a helper that ^6np8vdv can call.
  timestamp: 2026-10-03T18:53:33.640510+00:00
- actor: claude-code
  id: 01m41j171g7v15jh04tg51xmtm
  text: |-
    ### implement — changed
    - evidence: RED `swift test --filter ConnectionModelSessionTests/aConnectionThatClosesAfterTheNewSessionAnswerRegistersNoSession` failed with 2 issues (no error thrown, `openSessions` held session-1). GREEN: the same test passed. `swift build`: Build complete. `swift test`: 475 tests in 40 suites passed, 0 failures, 0 XCTest. Only warnings: the MLX "missing creator for mutated node" warning and the `SessionUpdateAggregator` deprecation (both accepted).
    - files: Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift (new private `register(_:openedOver:)`: compares the request connection with `self.connection`; when they differ, `markClosed()`, no register, throw `ConnectionError.closed`); Tests/FoundationModelsACPClientTests/HoldableTaskExecutor.swift (new test executor that holds its jobs while `whileHeld` runs); Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift (`newSessionGate`); Tests/FoundationModelsACPClientTests/Model/ConnectedModel.swift (`agentEnd`); Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift (fixture `newSessionGate`, `newSessionFinished(in:)`, and the new test).
    - The test is deterministic by events: agent gate holds the answer; the test holds the executor; opens the gate; waits for `OutgoingRequestEvent.finished` of `session/new`; closes the agent end; waits for `state == .disconnected`; then releases the executor. No fixed sleep.
    - Open: the `resumeSession(_:)` subtask waits for ^6np8vdv; that task must call `register(_:openedOver:)`. resumeSession was not touched.
    - next: /review
  timestamp: 2026-10-03T18:57:11.216812+00:00
- actor: claude-code
  id: 01m41jc6mbxfnb25cs8ztzh3yr
  text: |-
    ### test — green
    - evidence: swift build — complete, 0 new warnings. swift test — 475 tests in 40 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests — 103 tests in 14 suites passed, 0 failed, 0 skipped. swift test --filter ConnectionModelSessionTests x10 — 10 of 10 runs passed (14 tests each).
    - warnings: only the accepted ones. These are the mlx-swift "missing creator for mutated node" warning and the SessionUpdateAggregator deprecation warnings.
    - next: review. No code was changed. Nothing was committed.
  timestamp: 2026-10-03T19:03:11.243970+00:00
- actor: claude-code
  id: 01m41jcjn9z1fsz5fjex6kwdc5
  text: |-
    ### commit — changed
    - evidence: One local commit: fix(model): do not register a new session after its connection closed. The commit holds the newSession fix, the new tests, the test helpers, and the .kanban files. No push.
    - next: Review.
  timestamp: 2026-10-03T19:03:23.561958+00:00
position_column: doing
position_ordinal: '8180'
title: 'Model: newSession must not register a session after its connection closed'
---
## What
`ConnectionModel.newSession(_:)` in `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift` awaits the `session/new` response. Then it subscribes, makes the model, and registers it. The close of the connection runs in a separate main-actor task (`connectionDidClose`). If the response resolves and the connection closes before the `newSession` continuation runs, `closeOpenSessions()` runs first. Then `newSession` registers a new open model for a closed connection. That model stays in `openSessions` with `isClosed == false`, and a later `connect(over:)` does not remove it.

- [x] After the await, compare the local connection with `self.connection`. When they differ, close the new model (`markClosed()`), do not register it, and throw `ConnectionError.closed`.

The same check in `resumeSession(_:)` moved to task ^6np8vdv, because `resumeSession(_:)` does not exist yet and waits for an upstream marker.

## Acceptance Criteria
- [x] A `session/new` whose connection closes before the continuation runs leaves `openSessions` empty and throws `ConnectionError.closed`.

## Tests
- [x] Add a test in `Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift` that holds the agent answer with an `UpdateGate`, closes the connection after the answer is on the wire, and checks the result. Use events to wait, never fixed sleeps.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.