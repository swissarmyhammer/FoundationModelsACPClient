---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m41vj0390yrx0hzq4pa0b1hk
  text: |-
    Research done.
    - Upstream f72b8ad: `ClientSideConnection.listSessions(ListSessionsRequest(cursor:cwd:))` gives `ListSessionsResponse(sessions: [SessionInfo], nextCursor: SessionListCursor?)`; `deleteSession(DeleteSessionRequest(sessionId:))` gives `DeleteSessionResponse`. `SessionInfo` has `title: String?`, `updatedAt: String?`, `meta: JSONValue?`; `SessionInfoUpdate` has the same three fields as `PatchField`.
    - `ClientRequestSpan.Method` has no list or delete name, so the model adds them to `ConnectionModel.WireMethod` (as login and logout do).
    - SessionModel folds `session_info_update` in `reflect(_:)` (`.sessionInfoChanged`). The new internal callback goes there.
    - ScriptedStubAgent throws methodNotFound for `session/list` and has no `deleteSession` (the protocol default throws). It needs pages per cursor, a gate per cursor, and a record of the list and delete requests.
    - CONFLICT: `canCloseSessions` is `capabilities.session != nil`, and `canDeleteSessions` is `capabilities.session?.delete != nil`. Thus `canDeleteSessions` is true only when `canCloseSessions` is true. The card branch "else `markClosed()` and `unregister` locally (no request)" and the acceptance criterion "without the close capability it closes locally and sends only delete" can never occur, and no test can reach them. The `dead-code` rule forbids a branch with a condition that is always false.
  timestamp: 2026-10-03T21:43:38.345665+00:00
- actor: claude-code
  id: 01m41vwavhx7p0ct0b7sh7c1vq
  text: |-
    Implementation landed (TDD: the new suite failed to compile first because `WireMethod.listSessions` / `deleteSession` and the list API did not exist; then 11 of 11 passed).

    What is done:
    - `ConnectionModel+List.swift`: `hasMoreSessions`, `refreshSessions(cwd:)`, `loadMoreSessions()`, private `loadSessionPage(_:over:merge:)`, `patchListedSession(_:with:)`, `deleteSession(_:)`, and `WireMethod.listSessions` / `WireMethod.deleteSession`.
    - `ConnectionModel.swift`: stored `sessions`, `sessionListCursor`, `sessionListWorkingDirectory`, `sessionListGeneration`. `makeSessionModel` sets the new `SessionModel.sessionInfoDidChange` callback, so each model that the connection makes reports to the list (also during a replay).
    - `SessionModel.swift`: internal `sessionInfoDidChange` callback, called from `reflect(_:)` through `changeSessionInfo(_:)`.
    - Generation rule: the start of each refresh AND each page that lands change the generation. Thus a page from an older refresh is discarded, and two concurrent `loadMoreSessions()` calls with the same cursor cannot append the same page two times.
    - A refresh clears the cursor at its start, so a `loadMoreSessions()` during a refresh does not send the old cursor with the new `cwd`.
    - Test support: `ScriptedStubAgent` got `sessionListPages` / `sessionListGates` (keyed by cursor), `listRequests`, `deleteRequests`, and `deleteSession`; `ConnectedModel` got `listRequests` and `deleteRequests`.

    BLOCKER (needs a person):
    - The card item "else `markClosed()` and `unregister` locally (no request)" and the acceptance criterion "without the close capability it closes locally and sends only delete" cannot occur. `canCloseSessions` is `capabilities.session != nil`; `canDeleteSessions` is `capabilities.session?.delete != nil`. Thus `canDeleteSessions == true` gives `canCloseSessions == true`. No agent can advertise delete without close in the alpha.7 schema at f72b8ad (`SessionCapabilities` has `delete`, but no `close` flag).
    - The `dead-code` rule forbids a branch whose condition is always false, and no test can make the branch run. This is a true conflict between the card and the rule, so I did not write the branch. `deleteSession` calls `close(_:)` for an open session; `close(_:)` itself checks `canCloseSessions`.
    - Decision needed: (a) drop that branch and the second half of that criterion from the card, or (b) give `canCloseSessions` its own source (for example an upstream `session.close` capability) so the branch can run and be tested.

    Not in scope, noted: `connect(over:)` does not clear `sessions` or the cursor, so a new connection keeps the list of the last agent until the host refreshes.
  timestamp: 2026-10-03T21:49:17.041224+00:00
- actor: claude-code
  id: 01m41vwet2qt07ms9hb6vr5kmd
  text: |-
    ### implement — stuck
    - evidence: 6 files — Sources/FoundationModelsACPClient/Model/ConnectionModel+List.swift (new), Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Sources/FoundationModelsACPClient/Model/SessionModel.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelListTests.swift (new), Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift, Tests/FoundationModelsACPClientTests/Model/ConnectedModel.swift. `swift test --filter ConnectionModelListTests`: 11 passed. `swift build`: no warning other than the permitted ones. `swift test`: 508 tests in 41 suites passed. `swift test --package-path IntegrationTests`: 103 tests in 14 suites passed.
    - gap: the "close locally when there is no close capability" branch and its acceptance criterion cannot occur, because `canDeleteSessions` is true only when `canCloseSessions` is true (alpha.7 has no separate `session.close` capability). The `dead-code` rule forbids the branch. A person must change the card or the capability source.
    - next: a person decides on the blocker; then `/implement ^c5tywbr` again, or `/review` if the card changes.
  timestamp: 2026-10-03T21:49:21.090479+00:00
- actor: claude-code
  id: 01m41w0a8vm6mqqntydbaheqrq
  text: |-
    ### test — green
    - evidence: swift build — complete, 0 new warnings. swift test — 508 tests in 41 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests — 103 tests in 14 suites passed, 0 failed, 0 skipped.
    - warnings: only the accepted mlx-swift warning (missing creator for mutated node) appears in each run.
    - open: the implement step is still stuck on one card item. The item is deleteSession without close capability (markClosed and unregister locally). A person must decide. This test run did not change the item.
    - next: a person decides the open item. Then review.
  timestamp: 2026-10-03T21:51:27.515554+00:00
- actor: claude-code
  id: 01m41w0nkg8ebkxrq99j0zp78r
  text: |-
    ### commit — changed
    - evidence: One local commit: feat(model): add the session list and deleteSession to ConnectionModel. The sha is in the git log. The commit is not pushed.
    - next: One card item waits for a decision by a person: a local close without the close capability. The task stays in its column.
  timestamp: 2026-10-03T21:51:39.120295+00:00
- actor: claude-code
  id: 01m41w0wx3q356yagpjrs08nsb
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — the card item "else markClosed() and unregister locally (no request)" and the criterion "without the close capability it closes locally and sends only delete" cannot occur: canDeleteSessions (session.delete != nil) gives canCloseSessions (session != nil), and alpha.7 at f72b8ad has no separate session.close flag. The dead-code rule forbids the branch. A person must choose: (a) remove the branch and that part of the criterion from the card, or (b) get a separate upstream session.close capability.
    - test: green — swift test 508/508, IntegrationTests 103/103
    - commit: 80979a4 feat(model): add the session list and deleteSession to ConnectionModel (partial checkpoint)
    - review: not run — the task is stuck on the open card item
    - next: after the decision, /finish c5tywbr.
  timestamp: 2026-10-03T21:51:46.595387+00:00
depends_on:
- 01M3YR1XW7S2KVG2ABV6NP8VDV
- 01M3YRB9RRT2GXY0Q47K0BRVV6
position_column: doing
position_ordinal: '80'
title: 'Model: ConnectionModel session list and deleteSession'
---
## What
Add the session list to `ConnectionModel` in `Sources/FoundationModelsACPClient/Model/ConnectionModel+List.swift`.

- [x] `sessions: [SessionInfo]`, `hasMoreSessions: Bool`, `refreshSessions(cwd:) async throws` (`requireCapability(canListSessions)`; stores the `cwd` filter; starts again at the first page and replaces the list), `loadMoreSessions() async throws` (sends the stored `nextCursor` with the stored `cwd`, and appends; sends no request when there is no cursor).
- [x] Each refresh gets a new generation number. A page that arrives for an older generation (a `loadMoreSessions` that was in flight when a refresh started) is discarded.
- [x] A `session_info_update` of an open session patches its item in `sessions`. The SessionModel tells the ConnectionModel through an internal callback when its `sessionInfo` changes.
- [ ] `deleteSession(_ id:) async throws` (`requireCapability(canDeleteSessions)`): if the session is open, close it first: `close(_:)` when `canCloseSessions`, else `markClosed()` and `unregister` locally (no request). Then send `session/delete`, then remove it from `sessions`.
  - BLOCKED (see the comments): the `close(_:)` path, the delete, and the removal are done. The "else `markClosed()` and `unregister` locally" branch is not written: `canDeleteSessions` is true only when `canCloseSessions` is true, so the branch can never run, and the `dead-code` rule forbids it.

## Acceptance Criteria
- [x] Two pages load in order with the same `cwd`, `hasMoreSessions` is false after the last page, and a refresh starts at page one.
- [x] A page from an older refresh does not change `sessions`.
- [x] A title change on an open session shows in `sessions`.
- [ ] Delete of an open session sends close, then delete, and removes the item; without the close capability it closes locally and sends only delete.
  - The first half passes (`deleteOfAnOpenSessionSendsCloseThenDeleteAndRemovesTheItem`). The second half is BLOCKED: no agent can advertise `session/delete` without `session/close`.
- [x] List and delete against an agent without the capability throw and send nothing.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/ConnectionModelListTests.swift` over `InMemoryTransport.pair()` with a scripted agent that pages (and can hold a page until released, for the generation test), that sends a `session_info_update`, and that records the order and the parameters of its requests.
- [x] `swift test --filter ConnectionModelListTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.