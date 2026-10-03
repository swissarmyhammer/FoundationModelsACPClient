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
depends_on:
- 01M3YR0RQGPVCP3RV2MCCDM82C
position_column: todo
position_ordinal: '8680'
title: 'Model: ConnectionModel connect, state transitions, open-session registry, and close on disconnect'
---
## What
New `@MainActor @Observable public final class ConnectionModel` in `Sources/FoundationModelsACPClient/Model/ConnectionModel.swift`. This task is the base only: connect, state, the registry of open sessions, and close on disconnect. Initialize/auth (task "ConnectionModel initialize...") and the `Client` routing (task "ModelClient routing...") are separate tasks.

- [ ] `init(coalescingCadence: Duration = SessionModel.defaultCoalescingCadence, clock: any Clock<Duration> = ContinuousClock(), logger: ACPLogger = .disabled)`. Each `SessionModel` that this connection makes gets the same cadence and clock (acp-client uses `.zero` and an injected clock).
- [ ] `state: ConnectionState` with `.connecting`, `.connected`, `.disconnected`, `.failed(any Error)` (`Equatable` by case). Transitions: `connect` sets `.connecting` before the `ClientSideConnection` is made and `.connected` after; the inner byte stream ends normally (EOF) or the host closes the connection → `.disconnected`; the inner byte stream throws → `.failed(error)`. Change `DisconnectSignal` so that it carries the optional error.
- [ ] `connect(over transport:, logger:, client wrap: @escaping @Sendable @MainActor (any Client) -> any Client = { $0 }) async -> ClientSideConnection`: move the code of `SwiftUIACPClient+Connect.swift` here (`DisconnectObservingTransport`, `DisconnectSignal`). The wrap gets the internal router as `any Client`; a wrapper must forward `sessionUpdate` and `elicitationComplete` (doc comment). Until the routing task is done, the router is a stub that answers cancel.
- [ ] `public private(set) var openSessions: [SessionId: SessionModel]`, `session(for:) -> SessionModel?`, and internal `register(_ model:)` / `unregister(_ id:)`. The factory task uses them; tests here use `register` directly.
- [ ] On `.disconnected` or `.failed`: call `markClosed()` on each open SessionModel (it cancels their pending items) and clear `openSessions`.

## Acceptance Criteria
- [ ] `state` is `.connecting`, then `.connected`; it becomes `.disconnected` at agent EOF and `.failed` when the transport throws.
- [ ] A disconnect closes every registered SessionModel and cancels its pending permission.
- [ ] A SessionModel that the connection makes uses the cadence and clock given to `init`.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/ConnectionModelTests.swift` over `InMemoryTransport.pair()` (reuse `TransportTestSupport.swift`) plus a throwing test transport: the four states, close on disconnect with a registered model that holds a pending permission, cadence/clock pass-through.
- [ ] `swift test --filter ConnectionModelTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.