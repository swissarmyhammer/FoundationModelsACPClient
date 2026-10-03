---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m41fzv2zqw7709185k290e6h
  text: |-
    Research (implement step):
    - Pinned FoundationModelsACP 60854b6 gives `ClientSideConnection.subscribeToOutgoingRequests() -> AsyncStream<OutgoingRequestEvent>` (`.started(id:method:)`, `.finished(id:)`) and the synchronous `inFlightMethod(for:)`. The stream replays in-flight starts, sends `finished` for each in-flight request on close, then finishes. The upstream API can do what the task needs.
    - `PendingElicitation` has `requestId` already. It has no `requestMethod`. The plan adds a stored `requestMethod: String?` with an explicit init that has a `nil` default, so `SwiftUIACPClient` and `SessionModel` call sites do not change.
    - Race: `.finished(id)` can arrive on the main actor before the request-scope hook adds its item. The hook checks `connection.inFlightMethod(for:)` on the main actor. When it gives `nil`, the request is over and the hook answers `cancel` at once. `PendingRequestQueue.awaitResponse` adds the item with no suspension point after that check, so a later `.finished` always finds the item.
    - The agent handler cannot see its own inbound request id. The test reads the login id from `subscribeToOutgoingRequests()` on the client side and sends the request-scope elicitation through the agent-side connection while the stub holds `auth/login` behind an `UpdateGate`. `ScriptedStubAgent` gets one new optional `loginGate` parameter.
    - Existing `ModelClientTests.aRequestScopedElicitationGoesToTheConnectionHookThatAnswersCancel` sends a request id that is not in flight, so it still gets `cancel`.
  timestamp: 2026-10-03T18:21:29.055629+00:00
- actor: claude-code
  id: 01m41ggpj23fbbf6axfvkzeqzw
  text: |-
    Implementation landed (TDD):
    - RED: `swift test --filter ConnectionModelElicitationTests` failed to compile, because `ConnectionModel` had no `pendingElicitations`, `acceptElicitation`, `declineElicitation`, `cancelElicitation`, and `PendingElicitation` had no `requestMethod`.
    - GREEN: the same filter passes, 9 tests.
    - `ConnectionModel` holds a `PendingRequestQueue<PendingElicitation, CreateElicitationResponse>` and one `requestWatch` task per connection. `connect` starts the task from `subscribeToOutgoingRequests()`; `.finished(id)` cancels each item with that `requestId`. `connectionDidClose` (disconnected and failed) and each new `connect` cancel the task and every item.
    - `awaitRequestScopedElicitation(_:requestId:)` reads `inFlightMethod(for:)` and adds the item on the main actor with no suspension between, so a `.finished` cannot slip between the lookup and the add. It gives `nil` when the request is not in flight; `ModelClient` then answers `cancel` and logs one warning (`ModelClientTests` test renamed to `aRequestScopedElicitationForARequestNotInFlightAnswersCancelWithOneWarning`).
    - New shared `PendingRequestQueue.complete(elicitationId:)` (in `PendingElicitation.swift`). `SessionModel`, `SwiftUIACPClient` and `ConnectionModel` all use it, so the url-mode match exists one time.
    - Test support: `ScriptedStubAgent` gets an optional `loginGate`; `ElicitationFixtures.start(_:over:until:)` is the shared starter (`ModelClientTests` uses it too); `InitializeFixtures` is no longer `private`.
    - Extra behavior beyond the card, with its own test: a new `connect` cancels the pending elicitations of the last connection, because the model stops reading the old request events. Without it such an item could never leave the list.
    - Not done: no `ARCHITECTURE.md` exists, so no update is due.
  timestamp: 2026-10-03T18:30:41.474067+00:00
- actor: claude-code
  id: 01m41ggva6whbty4x1trfxf5e5
  text: |-
    ### implement — changed
    - evidence: `swift build` exit 0, only the accepted MLX "missing creator for mutated node" warning; `swift test` 461 tests in 39 suites passed, 0 failures, only the permitted `SessionUpdateAggregator` deprecation warnings; `swift test --filter ConnectionModelElicitationTests` 9 passed. Files: Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Elicitation.swift, Sources/FoundationModelsACPClient/Model/ModelClient.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift, Sources/FoundationModelsACPClient/PendingElicitation.swift, Sources/FoundationModelsACPClient/SwiftUIACPClient.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelElicitationTests.swift (new), Tests/FoundationModelsACPClientTests/Model/ModelClientTests.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift, Tests/FoundationModelsACPClientTests/ElicitationFixtures.swift, Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift.
    - next: /review
  timestamp: 2026-10-03T18:30:46.342422+00:00
- actor: claude-code
  id: 01m41gmtd2732ks9473qm1f2g8
  text: |-
    ### test — green
    - evidence: swift build: complete. swift test: 461 tests in 39 suites passed. swift test --package-path IntegrationTests: 103 tests in 14 suites passed. 0 failures, 0 skipped.
    - warnings: only accepted ones. These are the mlx-swift "missing creator for mutated node" warning and the SessionUpdateAggregator deprecation warnings.
    - next: review
  timestamp: 2026-10-03T18:32:56.482647+00:00
- actor: claude-code
  id: 01m41gn58aapzkh0h3ak22y5hv
  text: |-
    ### commit — changed
    - evidence: one local commit "feat(model): keep request-scoped elicitations on ConnectionModel until their request finishes". The sha is in the step record that the commit step returns. Tests were green before the commit. No push.
    - next: review
  timestamp: 2026-10-03T18:33:07.594395+00:00
depends_on:
- 01M3YRBGEKBG5X2Z9MFCFH2WSW
- 01M3YRB9RRT2GXY0Q47K0BRVV6
position_column: doing
position_ordinal: '80'
title: 'Model: ConnectionModel request-scoped elicitations, removed when their request finishes'
---
## What
Add request-scoped elicitations to `ConnectionModel` in `Sources/FoundationModelsACPClient/Model/ConnectionModel+Elicitation.swift`. This fills the request-scope hook that task cfh2wsw left.

Upstream API (foundationmodelsacp-c7, task ^swjqyk4): `ClientSideConnection` gives outgoing request events `.started(id, method)` and `.finished(id)` (success, error, cancel, close), and a method lookup for an in-flight id. The elicitation scope is `.request(ElicitationRequestScope)` with `requestId: RequestId`. The schema does not limit which client requests can cause one; `auth/login` (task k0brvv6) is the usual one. Use the final names from gate task 81s5j74.

- [x] `pendingElicitations: [PendingElicitation]` on ConnectionModel; each item has `requestId` (added in task pfcg77p) and `requestMethod: String?` from the lookup, so the UI can show which operation asked. Reply methods: `acceptElicitation(_:content:)`, `declineElicitation(_:)`, `cancelElicitation(_:)`. Reuse `PendingRequestStates`.
- [x] The request-scope hook of `ModelClient` adds items here. The `elicitationComplete` hook resolves a url-mode item here by `elicitationId`.
- [x] At connect, start one task that reads the request events. On `.finished(id)`, cancel and remove every pending item with that `requestId`.
- [x] On `.disconnected` or `.failed`, cancel every item in this list.

## Acceptance Criteria
- [x] A request-scope elicitation that the agent sends during `login(_:)` shows in `pendingElicitations` with its `requestId` and method `auth/login`.
- [x] When that request completes or fails, the item is removed and the agent receives `cancel` (if it was not answered).
- [x] Accept, decline and cancel resume the agent's call exactly one time.
- [x] A url-mode `elicitation/complete` closes the matching request-scope item.
- [x] A disconnect cancels every item.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/ConnectionModelElicitationTests.swift` over `InMemoryTransport.pair()` with a scripted agent that sends a request-scope elicitation while it handles `auth/login`: the three replies, url-mode completion, removal on request success, removal on request error, removal on disconnect.
- [x] `swift test --filter ConnectionModelElicitationTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.