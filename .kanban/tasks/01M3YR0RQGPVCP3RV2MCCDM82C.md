---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3ywyds9x48cmg1g99h3p3gb
  text: 'Name correction (seen on upstream main 0d3e88a, 2026-10-02): the subscription field is `SessionUpdateSubscription.hasMissedUpdates`, not `missedUpdates`. Use the upstream name where this task says `missedUpdates`. The same applies to task 6np8vdv.'
  timestamp: 2026-10-02T18:10:10.857953+00:00
- actor: claude-code
  id: 01m412t160qvg4hrtbgqv0xxpw
  text: 'From ^65x5kjr: `SessionModel` now has internal `finishUpdateTaps()` (in `SessionModel+Coalescing.swift`), which finishes each `updateTap()` stream. `markClosed()` must call `flushPendingChunks()` and then `finishUpdateTaps()`. When the attached subscription ends, call `finishUpdateTaps()` too. `apply(_:)` now buffers chunks with the 33 ms default cadence; a test that needs each chunk at once makes the model with `coalescingCadence: .zero`.'
  timestamp: 2026-10-03T14:31:07.200373+00:00
depends_on:
- 01M3YRC0ERS5FADQYB965X5KJR
- 01M3YR18MVWMMHJGQ69PFCG77P
position_column: todo
position_ordinal: '8380'
title: 'Model: SessionModel stream attachment, replay, missed updates, and close'
---
## What
Add the stream life of `SessionModel` in `Sources/FoundationModelsACPClient/Model/SessionModel+Stream.swift`. All of it is internal; only `ConnectionModel` calls it. The UI never subscribes itself.

Upstream API (foundationmodelsacp-c7, task ^1heg5df): `connection.subscribe(to: SessionId) -> SessionUpdateSubscription` with `updates: AsyncStream<SessionUpdate>` and `missedUpdates: Bool`. The first subscriber takes the buffer and the mark; then both are cleared. Use the final names from gate task 81s5j74.

- [ ] `attach(_ subscription: SessionUpdateSubscription)`: starts one `@MainActor` task that calls `apply` for each update in order. `subscription.missedUpdates == true` sets public `hasMissedUpdates = true`.
- [ ] Replay: `beginReplay(replayFrom: ReplayFrom?)` sets `isReplaying = true` before the `session/resume` request. If this model already has a transcript (resume of an open session), it first calls the engine `reset()` and clears `transcript` and the last-value state, because a replayed `*_chunk` appends again and doubles the text. `endReplay(succeeded: Bool)` sets `isReplaying = false`. A successful replay with `replayFrom == .start` gives the full retained history, so it sets `hasMissedUpdates = false`; any other result keeps the flag.
- [ ] Public `history: SessionHistory` with `.live` and `.retained(replayFrom: ReplayFrom)`. It is a client-side value: take `replayFrom` from the `ResumeSessionRequest` that was sent (the response has no history field). A request with `replayFrom == nil` keeps `.live`.
- [ ] `markClosed()`: calls `flushPendingChunks()`, cancels the stream task, finishes the `updateTap()` streams, calls `cancelAllPending()` (task pfcg77p), sets `isClosed = true`. After close, `apply` changes nothing.

## Acceptance Criteria
- [ ] Updates on the attached subscription land in order in the model.
- [ ] `missedUpdates == true` gives `hasMissedUpdates == true`; a later successful `.start` replay clears it.
- [ ] A second replay into a model that has a transcript gives the same transcript as one replay (no doubled chunk text), and the entry objects are new.
- [ ] `isReplaying` is true between `beginReplay` and `endReplay`, and false after a failure.
- [ ] After `markClosed()`, `isClosed == true`, no pending item stays, the tap stream ends, and new updates change nothing.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift`: a hand-made subscription; overflow flag set and cleared by a `.start` replay; replay flags and `history`; double-replay test with chunk updates; close stops the fold, ends the tap, cancels the stream task, and cancels a pending permission.
- [ ] `swift test --filter SessionModelStreamTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.