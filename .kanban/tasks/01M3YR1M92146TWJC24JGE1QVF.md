---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m40stsxqmcp30zstdtgkj2yf
  text: |-
    CHANGE OF APPROACH (foundationmodelsacp-c7, 2026-10-03): FoundationModelsACP main 284e002 has a public close signal. Use it for `ConnectionModel.state`, in place of the plan to change `DisconnectSignal` so that it carries the error.

    ```swift
    public enum ConnectionCloseReason: Sendable {
        case endOfInput                  // -> .disconnected
        case transportFailed(any Error)  // -> .failed(error)
        case closedLocally               // close() was called -> .disconnected
    }
    // ClientSideConnection
    public var closed: ConnectionCloseReason { get async }
    ```
    - It fires exactly one time, after every inbound handler (`session/request_permission`, `elicitation/create`) has ended. A late waiter gets the reason at once.
    - Do NOT await it inside an inbound handler (deadlock).
    - A failed WRITE does not close the connection; only that request fails. So `transportFailed` means the input stream failed.
    - Pattern: `Task { let reason = await connection.closed; await MainActor.run { model.apply(reason) } }`.

    Steps for this task:
    - First run `swift package update FoundationModelsACP` and confirm the pin is 284e002 or later.
    - Map the three reasons to `.disconnected` / `.failed(error)` / `.disconnected`.
    - Keep `DisconnectObservingTransport` only if something else still needs it (for example the teardown of `AgentProcess` on close). If not, delete it and `DisconnectSignal`.
    - The tests for `.failed` use a transport whose byte stream throws.
  timestamp: 2026-10-03T11:54:15.351861+00:00
- actor: claude-code
  id: 01m41ar8w7dgf6h6c8c0nwpfxe
  text: |-
    Research (implement step):
    - The pin of FoundationModelsACP is 60854b6 (it includes 284e002). `ClientSideConnection.closed` and `ConnectionCloseReason` are there. The pin does not change.
    - `ConnectionState` already exists in `SwiftUIACPClient.swift` (cases `.disconnected`, `.connected`, `Hashable`). Two types with one name cannot exist in the module, so this task moves the enum to `Model/ConnectionState.swift` and adds `.connecting` and `.failed(any Error)`, with `==` and `hash(into:)` by case. `SwiftUIACPClient` sets only `.connected` and `.disconnected`, as before.
    - `ClientSideConnection.close()` cancels the read loop. The cancel ends the iteration of the transport bytes, so the `onTermination` of the `AgentProcess` stream tears the agent down. Thus no code needs `DisconnectObservingTransport` for the teardown. Plan: delete `DisconnectObservingTransport` and `DisconnectSignal`, and make the old `SwiftUIACPClient.connect(over:logger:client:)` observe `closed` too (it sets `.disconnected` for each reason, as before). The integration `AgentProcessTests` prove the teardown.
    - The pending permission and elicitation queues use `withTaskCancellationHandler`, so the cancel of an inbound handler on close resumes the handler, and `closed` does not wait for ever.
    - EOF in a unit test: `InMemoryTransport.pair()`, then `close()` on the agent end finishes the bytes of the client end.
    - The stub router is `ModelClient` in `Model/ModelClient.swift` (the name of the routing task ^cfh2wsw). It answers `cancelled` / `cancel`.
  timestamp: 2026-10-03T16:49:58.151443+00:00
- actor: claude-code
  id: 01m41b6gv23v2wszbsgtz4x10y
  text: |-
    Implementation landed (TDD: the new ConnectionModelTests did not compile first, because `ConnectionModel` and the new states were missing; then 14/14 passed).
    - `Model/ConnectionModel.swift`: `init(coalescingCadence:clock:logger:)`, `state`, `connect(over:logger:client:)`, `openSessions`, `session(for:)`, internal `register(_:)`, `unregister(_:)` and `makeSessionModel(sessionId:requestSender:)` (it gives the cadence and clock of `init` to the new model; the factory task uses it). The `logger:` of `connect` is `ACPLogger?`; `nil` uses the logger of `init`.
    - `connect` sets `.connecting`, calls the wrap with the router, makes the `ClientSideConnection`, sets `.connected`, then observes `closed` in a task of its own (never in an inbound handler). The close maps `.endOfInput` and `.closedLocally` to `.disconnected` and `.transportFailed(error)` to `.failed(error)`, calls `markClosed()` on each open model and empties `openSessions`. A close of an earlier connection changes nothing (identity check).
    - `Model/ConnectionState.swift`: the enum moved here from `SwiftUIACPClient.swift`, with the new cases `.connecting` and `.failed(any Error)`. `==` and `hash(into:)` compare the case only. `init(closedBecause:)` holds the mapping.
    - `Model/ModelClient.swift`: the stub router (a struct). It answers `cancelled` / `cancel` and ignores the two notifications. Task ^cfh2wsw replaces it.
    - `ClientSideConnection+Close.swift`: `onClose(_:)` runs a main-actor handler one time with the close reason. `ConnectionModel` and the old `SwiftUIACPClient.connect(over:logger:client:)` both use it.
    - `DisconnectObservingTransport` and `DisconnectSignal` are deleted. Nothing needs them: `close()` cancels the read loop, and that cancel ends the `AgentProcess` stream, which tears the agent down. The integration `AgentProcessTests` pass. The comment of `FrameTeeTransport.swift` named the deleted type; it now describes the shape directly.
    - Tests: `startPermission(on:_:)` moved from a private helper of `SessionModelPendingTests` to `SessionModelFixtures`, so `ConnectionModelTests` reuses it and no copy exists.
    - Note for ^0w14d6x: `ConnectionState` now lives in `Model/ConnectionState.swift`, so the removal of `SwiftUIACPClient.swift` does not remove it.
  timestamp: 2026-10-03T16:57:45.058860+00:00
- actor: claude-code
  id: 01m41b6mv95f0p31bg5w9d1y47
  text: |-
    ### implement — changed
    - evidence: 10 files — Sources/FoundationModelsACPClient/Model/ConnectionModel.swift (new), Sources/FoundationModelsACPClient/Model/ConnectionState.swift (new), Sources/FoundationModelsACPClient/Model/ModelClient.swift (new), Sources/FoundationModelsACPClient/ClientSideConnection+Close.swift (new), Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift, Sources/FoundationModelsACPClient/SwiftUIACPClient.swift, Sources/AcpClientCore/FrameTeeTransport.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelTests.swift (new), Tests/FoundationModelsACPClientTests/Model/SessionModelFixtures.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelPendingTests.swift. `swift build`: exit 0, only the accepted MLX "missing creator" warning. `swift test --filter ConnectionModelTests`: 14/14 pass. `swift test`: 428 tests in 36 suites pass, no new warning (only the permitted `SessionUpdateAggregator` deprecations). `swift build --package-path IntegrationTests`: exit 0. `swift test --package-path IntegrationTests`: 103 tests in 14 suites pass.
    - next: /review
  timestamp: 2026-10-03T16:57:49.161140+00:00
- actor: claude-code
  id: 01m41bgkx2erx82q6yac1vhbqs
  text: |-
    ### test - green
    - evidence: root `swift build` x2 and `swift test` x2: 428 tests in 36 suites passed each time, 0 failed, 0 skipped. `swift build --package-path IntegrationTests` x2 and `swift test --package-path IntegrationTests` x2: 103 tests in 14 suites passed each time, 0 failed, 0 skipped. AgentProcessState teardown suites, interrupt suites and timeout suites passed. The AgentProcessTeardownTests known timing failure (task ^h5z930j) did not occur. Only warning: the accepted mlx-swift "missing creator for mutated node" warning.
    - next: review
  timestamp: 2026-10-03T17:03:15.874748+00:00
- actor: claude-code
  id: 01m41bgz8xgengqfjk6p0tyfdr
  text: |-
    ### commit — changed
    - evidence: one local commit "feat(model): add ConnectionModel with connect, state and close on disconnect". Tests: swift test 428/428 x2, IntegrationTests 103/103 x2.
    - note: DisconnectObservingTransport is replaced by ClientSideConnection.closed.
    - next: review
  timestamp: 2026-10-03T17:03:27.517091+00:00
depends_on:
- 01M3YR0RQGPVCP3RV2MCCDM82C
position_column: doing
position_ordinal: '80'
title: 'Model: ConnectionModel connect, state transitions, open-session registry, and close on disconnect'
---
## What
New `@MainActor @Observable public final class ConnectionModel` in `Sources/FoundationModelsACPClient/Model/ConnectionModel.swift`. This task is the base only: connect, state, the registry of open sessions, and close on disconnect. Initialize/auth (task "ConnectionModel initialize...") and the `Client` routing (task "ModelClient routing...") are separate tasks.

- [x] `init(coalescingCadence: Duration = SessionModel.defaultCoalescingCadence, clock: any Clock<Duration> = ContinuousClock(), logger: ACPLogger = .disabled)`. Each `SessionModel` that this connection makes gets the same cadence and clock (acp-client uses `.zero` and an injected clock).
- [x] `state: ConnectionState` with `.connecting`, `.connected`, `.disconnected`, `.failed(any Error)` (`Equatable` by case). Transitions: `connect` sets `.connecting` before the `ClientSideConnection` is made and `.connected` after; the inner byte stream ends normally (EOF) or the host closes the connection → `.disconnected`; the inner byte stream throws → `.failed(error)`. Change `DisconnectSignal` so that it carries the optional error. (Superseded by the CHANGE OF APPROACH comment: the state comes from `ClientSideConnection.closed`, and `DisconnectSignal` is deleted.)
- [x] `connect(over transport:, logger:, client wrap: @escaping @Sendable @MainActor (any Client) -> any Client = { $0 }) async -> ClientSideConnection`: move the code of `SwiftUIACPClient+Connect.swift` here (`DisconnectObservingTransport`, `DisconnectSignal`). The wrap gets the internal router as `any Client`; a wrapper must forward `sessionUpdate` and `elicitationComplete` (doc comment). Until the routing task is done, the router is a stub that answers cancel.
- [x] `public private(set) var openSessions: [SessionId: SessionModel]`, `session(for:) -> SessionModel?`, and internal `register(_ model:)` / `unregister(_ id:)`. The factory task uses them; tests here use `register` directly.
- [x] On `.disconnected` or `.failed`: call `markClosed()` on each open SessionModel (it cancels their pending items) and clear `openSessions`.

## Acceptance Criteria
- [x] `state` is `.connecting`, then `.connected`; it becomes `.disconnected` at agent EOF and `.failed` when the transport throws.
- [x] A disconnect closes every registered SessionModel and cancels its pending permission.
- [x] A SessionModel that the connection makes uses the cadence and clock given to `init`.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/ConnectionModelTests.swift` over `InMemoryTransport.pair()` (reuse `TransportTestSupport.swift`) plus a throwing test transport: the four states, close on disconnect with a registered model that holds a pending permission, cadence/clock pass-through.
- [x] `swift test --filter ConnectionModelTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.