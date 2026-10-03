---
assignees:
- claude-code
depends_on:
- 01M3YR1XW7S2KVG2ABV6NP8VDV
- 01M3YRB9RRT2GXY0Q47K0BRVV6
position_column: todo
position_ordinal: '8880'
title: 'Model: ConnectionModel session list and deleteSession'
---
## What
Add the session list to `ConnectionModel` in `Sources/FoundationModelsACPClient/Model/ConnectionModel+List.swift`.

- [ ] `sessions: [SessionInfo]`, `hasMoreSessions: Bool`, `refreshSessions(cwd:) async throws` (`requireCapability(canListSessions)`; stores the `cwd` filter; starts again at the first page and replaces the list), `loadMoreSessions() async throws` (sends the stored `nextCursor` with the stored `cwd`, and appends; sends no request when there is no cursor).
- [ ] Each refresh gets a new generation number. A page that arrives for an older generation (a `loadMoreSessions` that was in flight when a refresh started) is discarded.
- [ ] A `session_info_update` of an open session patches its item in `sessions`. The SessionModel tells the ConnectionModel through an internal callback when its `sessionInfo` changes.
- [ ] `deleteSession(_ id:) async throws` (`requireCapability(canDeleteSessions)`): if the session is open, close it first: `close(_:)` when `canCloseSessions`, else `markClosed()` and `unregister` locally (no request). Then send `session/delete`, then remove it from `sessions`.

## Acceptance Criteria
- [ ] Two pages load in order with the same `cwd`, `hasMoreSessions` is false after the last page, and a refresh starts at page one.
- [ ] A page from an older refresh does not change `sessions`.
- [ ] A title change on an open session shows in `sessions`.
- [ ] Delete of an open session sends close, then delete, and removes the item; without the close capability it closes locally and sends only delete.
- [ ] List and delete against an agent without the capability throw and send nothing.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/ConnectionModelListTests.swift` over `InMemoryTransport.pair()` with a scripted agent that pages (and can hold a page until released, for the generation test), that sends a `session_info_update`, and that records the order and the parameters of its requests.
- [ ] `swift test --filter ConnectionModelListTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.