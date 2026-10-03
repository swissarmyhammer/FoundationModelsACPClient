---
assignees:
- claude-code
depends_on:
- 01M3YR0FJ4Z55VAXKXQ3KAM7GW
position_column: todo
position_ordinal: '8e80'
title: 'Model: SessionModel display-rate chunk coalescing and a raw update tap'
---
## What
Port the chunk coalescing of `ACPSessionState` to `SessionModel`, and add a raw update tap for non-UI consumers. New file `Sources/FoundationModelsACPClient/Model/SessionModel+Coalescing.swift`. Port the logic of `ACPSessionState.swift` (`pendingChunk(for:)`, `enqueue`, `scheduleFlushIfNeeded`, `flushPendingChunks`); do not copy the class.

- [ ] `SessionModel.init(sessionId:, coalescingCadence: Duration = SessionModel.defaultCoalescingCadence (33 ms), clock: any Clock<Duration> = ContinuousClock())`.
- [ ] `agent_message_chunk` and `agent_thought_chunk` go into a buffer that flushes on the cadence; any other update flushes first, then applies, so the applied order is the arrival order. `public func flushPendingChunks()`. With `.zero` cadence, each chunk applies at once.
- [ ] `public func updateTap() -> AsyncStream<SessionUpdate>`: each raw update, in arrival order, at arrival time (not delayed by coalescing). The stream finishes when the model closes or its subscription ends. acp-client uses it to write chunks to stdout as they arrive.

## Acceptance Criteria
- [ ] N chunks inside one cadence cause one observable write of the entry, and the final text is the same as one-by-one application.
- [ ] A non-chunk update flushes the buffer before it applies.
- [ ] `updateTap()` yields each update at once, also while the chunk buffer is not flushed.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/SessionModelCoalescingTests.swift`: port each case of `CoalescingTests.swift` with a manual clock; add tap order and tap timing tests.
- [ ] `swift test --filter SessionModelCoalescingTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.