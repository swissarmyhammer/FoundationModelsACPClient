---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m41dddn8masz3eeec081ktnz
  text: |-
    Research done.
    - `Client` (FoundationModelsACP 60854b6) is `Sendable` with four required methods. `ModelClient` is a non-isolated struct today; `ConnectionModel` is `@MainActor`, so the router must hop to the main actor with `await`. The handler task stays the same task, so task cancellation still reaches `awaitPermissionDecision` / `awaitElicitation`.
    - Scope shape: `CreateElicitationRequest.mode` is `.form(ElicitationFormMode)`, `.url(ElicitationUrlMode)` or `.unknown(String, JSONValue)`. Each known mode has its own `Scope` enum with exactly two cases, `.session(ElicitationSessionScope)` and `.request(ElicitationRequestScope)`. Only `.unknown` has no scope.
    - `PendingElicitation` already reads the scope in a private `WireScope`. Plan: move that reading to one internal `ElicitationScope` on `CreateElicitationRequest` (with an `unknownMode` case), so the router and `PendingElicitation` share one reader.
    - Cycle: ConnectionModel -> ClientSideConnection -> served client -> ModelClient. The router holds the model with `weak let` (Swift 6.4).
    - Logger: the effective connection logger (`logger ?? self.logger`) goes to the router. Each warning has the prefix `ModelClient: `, so a test can count only router warnings among the connection logs.
    - Request-scope hook: `ConnectionModel.awaitRequestScopedElicitation(_:)` answers `cancel`, and `completeRequestScopedElicitation(elicitationId:)` does nothing, until ^7jpv3jx.
    - No ARCHITECTURE.md in the project.
  timestamp: 2026-10-03T17:36:28.328842+00:00
- actor: claude-code
  id: 01m41dq3g4qjs7de43eapp70fe
  text: |-
    Implementation landed.
    - RED: 7 new tests in `ModelClientTests`. 6 failed against the stub router: 3 had no warning, and 3 timed out because no session model got the request. The request-scope test passed at once, because the stub answer (`cancel`) is the same as the hook answer.
    - GREEN: `ModelClient` now holds a `weak let model: ConnectionModel?` and the connection logger. It hops to the main actor to find the open session, then awaits `awaitPermissionDecision` / `awaitElicitation` on that model. `connect` gives the effective logger (`logger ?? self.logger`) to the router and to the connection.
    - New `ConnectionModel+Elicitation.swift`: `awaitRequestScopedElicitation(_:)` (hook, answers `cancel`), `completeElicitation(elicitationId:)` (each open session first, then the hook), `completeRequestScopedElicitation(elicitationId:)` (hook, does nothing). Task ^7jpv3jx fills the two hooks.
    - `PendingElicitation.swift`: the private `WireScope` became the internal `ElicitationScope` (`session` / `request` / `unknownMode(String)`) with `CreateElicitationRequest.elicitationScope`. `PendingElicitation` and `ModelClient` share this one reader. `SwiftUIACPClient` does not change; the old elicitation tests pass.
    - Note: the 8th test (`anElicitationCompleteThatNoSessionHoldsLeavesEachPendingElicitation`) was written after `completeElicitation(elicitationId:)`, so it passed on its first run. It calls `completeElicitation` directly, because a notification over the wire that changes nothing has no event to wait for.
    - Warnings: each router warning starts with `ModelClient: `. The tests count the messages of a test logger given to `ConnectionModel(logger:)`.
  timestamp: 2026-10-03T17:41:45.604987+00:00
- actor: claude-code
  id: 01m41dq6rqzdkeefq4amykkbyy
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPClient/Model/ModelClient.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Elicitation.swift (new), Sources/FoundationModelsACPClient/PendingElicitation.swift, Tests/FoundationModelsACPClientTests/Model/ModelClientTests.swift (new, 8 tests). `swift build`: complete, only the accepted MLX "missing creator for mutated node" warning. `swift test`: 451 tests in 38 suites passed, 0 failures; only the accepted MLX and `SessionUpdateAggregator` deprecation warnings.
    - next: /review
  timestamp: 2026-10-03T17:41:48.951409+00:00
- actor: claude-code
  id: 01m41dtxxhr4hck18db265hbjj
  text: |-
    ### test - green
    - evidence: swift build - complete. swift test - 451 tests in 38 suites passed. swift test --package-path IntegrationTests - 103 tests in 14 suites passed. 0 failures, 0 skipped.
    - warnings: only accepted ones. The mlx-swift "missing creator for mutated node" warning. The SessionUpdateAggregator deprecation warnings.
    - flake: AgentProcessTeardownTests did not fail. No rerun needed.
    - next: review.
  timestamp: 2026-10-03T17:43:50.961785+00:00
- actor: claude-code
  id: 01m41dvcq7rnhcb8q9tq7je7e1
  text: |-
    ### commit — changed
    - evidence: subject "feat(model): route permission and elicitation requests through ModelClient". Local commit. Not pushed. The sha is in the step block of the commit agent.
    - next: review
  timestamp: 2026-10-03T17:44:06.119465+00:00
- actor: claude-code
  id: 01m41e1kz8kep1tzqpwqb1xmwd
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (c983c6d); 5 files reviewed, 4 .kanban files not reviewed (.reviewignore); 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed.
    - next: none. The task is in done.
  timestamp: 2026-10-03T17:47:30.152899+00:00
- actor: claude-code
  id: 01m41e1tgx3gdqjax2eke28v49
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files (ModelClient.swift, ConnectionModel.swift, ConnectionModel+Elicitation.swift, PendingElicitation.swift, ModelClientTests.swift)
    - test: green — swift test 451/451, IntegrationTests 103/103
    - commit: c983c6d feat(model): route permission and elicitation requests through ModelClient
    - review: clean — task moved to done
  timestamp: 2026-10-03T17:47:36.861723+00:00
depends_on:
- 01M3YR1M92146TWJC24JGE1QVF
- 01M3YR18MVWMMHJGQ69PFCG77P
position_column: done
position_ordinal: c480
title: 'Model: ModelClient routes permission and elicitation requests to the models, with fallbacks'
---
## What
Replace the stub router of `ConnectionModel` with the real `Client` implementation, `ModelClient` (internal), in `Sources/FoundationModelsACPClient/Model/ModelClient.swift`. The host sees it only as `any Client` in the `connect(... client:)` wrap closure.

- [x] `requestPermission`: goes to `openSessions[sessionId].awaitPermissionDecision`. No open model for the session: answer `cancelled` at once and log a warning.
- [x] `createElicitation`: read the scope of the request. `.session(scope)` goes to `openSessions[scope.sessionId].awaitElicitation`; no open model: answer `cancel` and log a warning. `.request(scope)` goes to an internal ConnectionModel hook; until the request-scope task is done, the hook answers `cancel`. A mode or scope that the client does not know (for example an `.unknown` mode): answer `cancel` and log a warning.
- [x] `elicitationComplete`: give it to the session that holds that `elicitationId`; if no session holds it, give it to the ConnectionModel hook (request scope).
- [x] `sessionUpdate`: does nothing; the models read their subscription.

## Acceptance Criteria
- [x] A permission request and a session-scoped elicitation for an open session land in that model, and the UI reply reaches the agent.
- [x] For an unknown session, a permission answers `cancelled` and an elicitation answers `cancel`, with one warning each.
- [x] An unknown elicitation mode answers `cancel`.
- [x] A url-mode `elicitation/complete` closes the matching pending item.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/ModelClientTests.swift` over `InMemoryTransport.pair()` with a scripted agent (reuse `ElicitationFixtures.swift`), and a registered SessionModel: each route and each fallback, and the warning through a test logger.
- [x] `swift test --filter ModelClientTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.