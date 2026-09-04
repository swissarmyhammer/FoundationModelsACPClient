---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1p66df6rxracq0k6qxvekb6
  text: |-
    Research done. What matters for this change:

    - `ClientSideConnection.init(stream:logger:requestTimeout:_:)` takes a `@Sendable (ClientSideConnection) -> any Client` factory. It is a nonisolated `async` init, so the factory body runs off the main actor. The card's closure is `@MainActor`, so the overload must call it on the main actor (in `connect`, which is `@MainActor` because `SwiftUIACPClient` is) and hand the already-built `Client` to the factory as `{ _ in served }`. That also gives the "closure runs one time per connect" guarantee for free.
    - The card's closure takes only the container, not the connection, so eager evaluation loses nothing.
    - `Client` (in `FoundationModelsACP/Connection/Client.swift`) has four members, all `async`: `sessionUpdate(_:)`, `requestPermission(_:)`, `createElicitation(_:)`, `elicitationComplete(_:)`. A test wrapper can be a `@MainActor final class`, the same shape `SwiftUIACPClient` already uses to conform.
    - Test helpers already in the unit target: `InMemoryTransport.pair()`, `ScriptedStubAgent`, `makeInitializeRequest()`, `eventually(within:_:)`, `waitUntil(_:)`, `testSession`, `agentChunk(text:message:)`, `idleState(stopReason:)`.
    - `ForbiddenImportTests` scans `Sources/` for banned module imports; the change adds no import, so it stays green.
  timestamp: 2026-09-04T12:27:16.326599+00:00
- actor: claude-code
  id: 01m1p6jhseg98aykdk1hwr6hg0
  text: |-
    Followed `/tdd`. RED first: the four new tests were written before the overload existed, and `swift build --build-tests` failed with three `extra trailing closure passed in call` errors, one at each new call of `connect(over:logger:client:)`. That is the failure the missing feature causes, not a typo. GREEN after adding the overload: `swift test` reports 72 tests passed, zero failures, zero warnings.

    Design notes for the next agent:

    - The overload calls `client(self)` on the main actor and hands the result to the wire package as `{ _ in served }`. The wire factory is `@Sendable (ClientSideConnection) -> any Client` and is NOT main-actor isolated, so a lazy call from inside that factory would need `MainActor.assumeIsolated` and would run off the main actor. Eager evaluation avoids that, and it is also what makes "the closure runs one time per connect" true by construction rather than by care.
    - The two-argument `connect(over:logger:)` is now one line: `await connect(over: transport, logger: logger) { $0 }`. Its signature is byte-identical, so every caller — the README example, `IntegrationTests`, `AgentProcess`'s doc link — stands unchanged.
    - `PermissionStubAgent` in `PermissionRequestTests.swift` lost its `private`, so the seam test can reuse it instead of adding a fourth copy of the seven-method `Agent` conformance. Its own `permissionRequest()` helper stays private to that file.
    - The test wrapper answers `requestPermission` with `.cancelled`, which is the policy `^0y75z` ("Decline every permission request and elicitation") will need in the CLI. It branches on an exhaustive `switch` over a two-case enum, not a `guard`, because `noGuardInTests` and `state-modeling` both want that shape.

    ### implement — changed
    - evidence: 3 files, 264 insertions, 2 deletions — Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift, Tests/FoundationModelsACPClientTests/InProcessConnectionTests.swift, Tests/FoundationModelsACPClientTests/PermissionRequestTests.swift. `swift test`: 72 tests, 0 failures, 0 warnings. `sourcesHoldNoForbiddenImport` green; the file gained no import.
    - next: /review
  timestamp: 2026-09-04T12:33:53.966381+00:00
- actor: claude-code
  id: 01m1p7031mnsv2x8xf24jh69mw
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (b272400) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. Reviewed `Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift`, `Tests/FoundationModelsACPClientTests/InProcessConnectionTests.swift`, `Tests/FoundationModelsACPClientTests/PermissionRequestTests.swift`. `.kanban/` excluded by `.reviewignore`; `cli-plan.md` matched no validator.
    - next: task moves to done.
  timestamp: 2026-09-04T12:41:17.620372+00:00
- actor: claude-code
  id: 01m1p70gxaa4dynb94q3wh931d
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files (SwiftUIACPClient+Connect.swift, InProcessConnectionTests.swift, PermissionRequestTests.swift)
    - test: green — `swift package clean && swift test`, 72 passed, 0 failed, 0 skipped, 0 warnings
    - commit: b272400 feat(acp): add connect(over:logger:client:) overload for a wrapping Client
    - review: clean — zero new findings, 7 validators, task moved to done
  timestamp: 2026-09-04T12:41:31.818159+00:00
position_column: done
position_ordinal: 8b80
title: Give SwiftUIACPClient.connect a seam for a wrapping Client
---
## What

`Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift` ends with:

```swift
return await ClientSideConnection(stream: observed, logger: logger) { _ in self }
```

The `Client` the connection serves is hard-wired to the container itself.
`acp-client` must put a wrapper in front of the container, to decline
permission requests and elicitations that no person is there to answer. It
cannot do that today, and it cannot build the `ClientSideConnection` itself
either: it would lose `connectionState`, and
`DisconnectObservingTransport` is `internal` to the library.

Add an overload in the same file:

```swift
public func connect(
    over transport: any ACPTransport,
    logger: ACPLogger = .disabled,
    client: @escaping @Sendable @MainActor (SwiftUIACPClient) -> any Client
) async -> ClientSideConnection
```

The existing two-argument `connect(over:logger:)` keeps its behaviour and
becomes a call to the overload with `{ $0 }`, so no caller changes and the
disconnect wrapper stays in one place. Document that the closure receives the
container and returns the `Client` the connection serves, and that a wrapper
must forward `sessionUpdate(_:)` and `elicitationComplete(_:)` to the
container or the observable state goes stale.

This is a library change, and it is the only one this CLI work needs. Keep it
small, and keep `plan.md`'s import rule: this file gains no new import.

## Acceptance Criteria

- [ ] The two-argument `connect(over:logger:)` behaves exactly as before, and
      its existing tests pass unchanged.
- [ ] The new overload serves the `Client` the closure returns.
- [ ] `connectionState` becomes `.connected` and later `.disconnected` on the
      new overload exactly as on the old one.
- [ ] The closure runs one time per connect.
- [ ] `Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift`
      gains no import, so `ForbiddenImportTests` stays green.

## Tests

- [ ] Extend `Tests/FoundationModelsACPClientTests/InProcessConnectionTests.swift`:
      a test connects with a wrapper that counts `sessionUpdate(_:)` calls and
      forwards them, drives a scripted stub turn, and asserts both the counter
      moved and the container's session state holds the updates.
- [ ] One test asserts a wrapper that answers `requestPermission` itself is
      the one the agent reaches, and the container's
      `pendingPermissionRequests` stays empty.
- [ ] One test asserts the disconnect path on the new overload: the stream
      ends, and `connectionState` becomes `.disconnected`.
- [ ] One test asserts the old two-argument overload still serves the
      container itself.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.