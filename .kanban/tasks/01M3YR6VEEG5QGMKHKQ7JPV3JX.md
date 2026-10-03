---
assignees:
- claude-code
depends_on:
- 01M3YRBGEKBG5X2Z9MFCFH2WSW
- 01M3YRB9RRT2GXY0Q47K0BRVV6
position_column: todo
position_ordinal: 8b80
title: 'Model: ConnectionModel request-scoped elicitations, removed when their request finishes'
---
## What
Add request-scoped elicitations to `ConnectionModel` in `Sources/FoundationModelsACPClient/Model/ConnectionModel+Elicitation.swift`. This fills the request-scope hook that task cfh2wsw left.

Upstream API (foundationmodelsacp-c7, task ^swjqyk4): `ClientSideConnection` gives outgoing request events `.started(id, method)` and `.finished(id)` (success, error, cancel, close), and a method lookup for an in-flight id. The elicitation scope is `.request(ElicitationRequestScope)` with `requestId: RequestId`. The schema does not limit which client requests can cause one; `auth/login` (task k0brvv6) is the usual one. Use the final names from gate task 81s5j74.

- [ ] `pendingElicitations: [PendingElicitation]` on ConnectionModel; each item has `requestId` (added in task pfcg77p) and `requestMethod: String?` from the lookup, so the UI can show which operation asked. Reply methods: `acceptElicitation(_:content:)`, `declineElicitation(_:)`, `cancelElicitation(_:)`. Reuse `PendingRequestStates`.
- [ ] The request-scope hook of `ModelClient` adds items here. The `elicitationComplete` hook resolves a url-mode item here by `elicitationId`.
- [ ] At connect, start one task that reads the request events. On `.finished(id)`, cancel and remove every pending item with that `requestId`.
- [ ] On `.disconnected` or `.failed`, cancel every item in this list.

## Acceptance Criteria
- [ ] A request-scope elicitation that the agent sends during `login(_:)` shows in `pendingElicitations` with its `requestId` and method `auth/login`.
- [ ] When that request completes or fails, the item is removed and the agent receives `cancel` (if it was not answered).
- [ ] Accept, decline and cancel resume the agent's call exactly one time.
- [ ] A url-mode `elicitation/complete` closes the matching request-scope item.
- [ ] A disconnect cancels every item.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/ConnectionModelElicitationTests.swift` over `InMemoryTransport.pair()` with a scripted agent that sends a request-scope elicitation while it handles `auth/login`: the three replies, url-mode completion, removal on request success, removal on request error, removal on disconnect.
- [ ] `swift test --filter ConnectionModelElicitationTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.