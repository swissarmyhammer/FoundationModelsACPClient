---
assignees:
- claude-code
depends_on:
- 01M3YR1M92146TWJC24JGE1QVF
- 01M3YR18MVWMMHJGQ69PFCG77P
position_column: todo
position_ordinal: 8d80
title: 'Model: ModelClient routes permission and elicitation requests to the models, with fallbacks'
---
## What
Replace the stub router of `ConnectionModel` with the real `Client` implementation, `ModelClient` (internal), in `Sources/FoundationModelsACPClient/Model/ModelClient.swift`. The host sees it only as `any Client` in the `connect(... client:)` wrap closure.

- [ ] `requestPermission`: goes to `openSessions[sessionId].awaitPermissionDecision`. No open model for the session: answer `cancelled` at once and log a warning.
- [ ] `createElicitation`: read the scope of the request. `.session(scope)` goes to `openSessions[scope.sessionId].awaitElicitation`; no open model: answer `cancel` and log a warning. `.request(scope)` goes to an internal ConnectionModel hook; until the request-scope task is done, the hook answers `cancel`. A mode or scope that the client does not know (for example an `.unknown` mode): answer `cancel` and log a warning.
- [ ] `elicitationComplete`: give it to the session that holds that `elicitationId`; if no session holds it, give it to the ConnectionModel hook (request scope).
- [ ] `sessionUpdate`: does nothing; the models read their subscription.

## Acceptance Criteria
- [ ] A permission request and a session-scoped elicitation for an open session land in that model, and the UI reply reaches the agent.
- [ ] For an unknown session, a permission answers `cancelled` and an elicitation answers `cancel`, with one warning each.
- [ ] An unknown elicitation mode answers `cancel`.
- [ ] A url-mode `elicitation/complete` closes the matching pending item.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/ModelClientTests.swift` over `InMemoryTransport.pair()` with a scripted agent (reuse `ElicitationFixtures.swift`), and a registered SessionModel: each route and each fallback, and the warning through a test logger.
- [ ] `swift test --filter ModelClientTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.