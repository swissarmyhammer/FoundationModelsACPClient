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
- actor: claude-code
  id: 01m41btcpyqpdsnvk8fz7hwvdm
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit edfea8b). 1 finding (1 confirmed, 0 refuted): Sources/FoundationModelsACPClient/ClientSideConnection+Close.swift:17 `swift/concurrency` — the new public `onClose(_:)` uses an @escaping completion handler in place of async/await.
    - next: implement the finding (apply the cause to the whole file), then /review again.
  timestamp: 2026-10-03T17:08:36.190748+00:00
- actor: claude-code
  id: 01m41btp9j3241m99vzq513f2h
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 files (ConnectionModel, ConnectionState, ModelClient stub, ClientSideConnection+Close.swift; DisconnectObservingTransport deleted)
    - test: green — swift test 428/428 x2, IntegrationTests 103/103 x2
    - commit: edfea8b feat(model): add ConnectionModel with connect, state and close on disconnect
    - review: findings — Sources/FoundationModelsACPClient/ClientSideConnection+Close.swift:17
  timestamp: 2026-10-03T17:08:46.002132+00:00
- actor: claude-code
  id: 01m41c2dd386jq8b8cfhbc3g8m
  text: |-
    Finding fix (implement step):
    - Cause: the callback helper `onClose(_:)` on `ClientSideConnection`. The upstream API already gives `ClientSideConnection.closed: ConnectionCloseReason { get async }`, so the helper only wrapped an async value in a callback.
    - `Sources/FoundationModelsACPClient/ClientSideConnection+Close.swift` is deleted. Nothing else was in it.
    - `ConnectionModel.connect` and `SwiftUIACPClient.connect(over:logger:client:)` now each start their own task that does `await connection.closed` directly (with `[weak self]`), and then set the state. The comment at each site says why the wait must not run in an inbound handler.
    - The mapping from `ConnectionCloseReason` to `ConnectionState` stays the synchronous internal `ConnectionState.init(closedBecause:)`. No new callback API.
    - No test used `onClose`. TDD note: this is a refactor with no change in behavior, so no new test can fail first; the 14 `ConnectionModelTests` and the `SwiftUIACPClient` connect tests cover the four states and stay green.
  timestamp: 2026-10-03T17:12:59.043889+00:00
- actor: claude-code
  id: 01m41c2fr7smjwpe7bvpkc3bwn
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPClient/ClientSideConnection+Close.swift (deleted), Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift. `swift build`: exit 0, only the accepted MLX "missing creator" warning and the permitted `SessionUpdateAggregator` deprecations. `swift test`: 428 tests in 36 suites pass. `swift build --package-path IntegrationTests`: exit 0. `swift test --package-path IntegrationTests`: 103 tests in 14 suites pass. The finding `ClientSideConnection+Close.swift:17` is `- [x]`.
    - next: /review
  timestamp: 2026-10-03T17:13:01.447389+00:00
- actor: claude-code
  id: 01m41c7347tv7m05v7mn082pjg
  text: |-
    ### test - green (iteration 2, callback helper removed)
    - evidence: swift build (root) ok; swift test (root) 428 tests in 36 suites passed; swift build --package-path IntegrationTests ok; swift test --package-path IntegrationTests 103 tests in 14 suites passed. 0 failures, 0 skipped. Only warning: the accepted mlx-swift "missing creator for mutated node" warning.
    - next: review
  timestamp: 2026-10-03T17:15:32.359772+00:00
- actor: claude-code
  id: 01m41c7d5fw1q6kyf8c9pv7f6v
  text: |-
    ### commit — changed
    - evidence: refactor(model): await ClientSideConnection.closed directly; 5 files (removed ClientSideConnection+Close.swift onClose helper; callers await connection.closed). Tests: swift test 428/428, IntegrationTests 103/103.
    - next: review
  timestamp: 2026-10-03T17:15:42.639494+00:00
- actor: claude-code
  id: 01m41cdxxvj54xbsmf13kvfz1k
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 579c570). 0 findings (0 confirmed, 0 refuted, 7 attempted, 0 failed). 3 files reviewed. 5 code-hygiene tool rules did not read `Sources/FoundationModelsACPClient/ClientSideConnection+Close.swift`, because the commit deletes that file. The prior finding `ClientSideConnection+Close.swift:17` is `- [x]`.
    - next: none. The task moved to done.
  timestamp: 2026-10-03T17:19:16.411370+00:00
- actor: claude-code
  id: 01m41ce5a9qacwzm7gpn5q921w
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — callback helper removed; 3 files
    - test: green — swift test 428/428, IntegrationTests 103/103
    - commit: 579c570 refactor(model): await ClientSideConnection.closed directly
    - review: clean — task moved to done
  timestamp: 2026-10-03T17:19:23.977452+00:00
depends_on:
- 01M3YR0RQGPVCP3RV2MCCDM82C
position_column: done
position_ordinal: c280
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

## Review Findings (2026-10-03 12:03)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPClient/ClientSideConnection+Close.swift:17` `swift/concurrency` — New public method uses @escaping completion handler instead of async/await, limiting integration with structured concurrency and requiring callers to spawn manual tasks. Provide an async alternative: `func closed() async -> ConnectionCloseReason` or similar, exposing the internal `await closed` as a public async method so callers can use structured concurrency directly rather than callbacks.
