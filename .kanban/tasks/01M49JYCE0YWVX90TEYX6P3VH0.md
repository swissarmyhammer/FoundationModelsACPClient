---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4b606z15xqj3yqdyrcq98xt
  text: |-
    Research and implementation notes:
    - `SessionEntry.Kind.toolCall` holds a `ToolCallUpdate`. Its `toolCallId` is the ACP id. `TranscriptEntry(wire:)` is the only caller of `ToolCallEntry(wire:)`, so the signature change touches one site.
    - `toolCallEntry(for:)` reads `wireEntries[.toolCall(id)]`. `resetTranscript()` clears `wireEntries`. Thus the lookup gives `nil` after `beginReplay(replayFrom:)` with a cursor and a transcript that is not empty, and gives the new object after the replay adds the tool call again.
    - RED: the five new tests did not compile. The errors were "value of type 'ToolCallEntry' has no member 'toolCallId'" and "'toolCallEntry' is inaccessible due to 'private' protection level".
    - GREEN: `swift test --filter SessionModelFoldTests` gave 45 of 45 tests passed.
    - Refactor: `attachUnresolvedElicitationLinks(to:)` and `detachElicitationLinksFromToolCalls()` now read `ToolCallEntry.toolCallId`. They do not pattern-match `entry.id` as `.wire(.toolCall(id))` now. The behavior did not change.
    - The SwiftPM warning "missing creator for mutated node: .../mlx-swift_Cmlx.bundle/Contents/MacOS" shows in `swift build` and `swift test`. It comes from a dependency bundle node at build step 1, before this package compiles. This change did not cause it.
  timestamp: 2026-10-07T12:39:19.777608+00:00
- actor: claude-code
  id: 01m4b609a4ds6dt33q5k9wbtfz
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPClient/Model/ToolCallEntry.swift, Sources/FoundationModelsACPClient/Model/TranscriptEntry.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelFoldTests.swift. `swift test --filter SessionModelFoldTests`: 45 passed, 0 failed. `swift test`: 521 tests in 45 suites passed, 0 failed. `swift build`: complete, no new warning (only the dependency warning "missing creator for mutated node" for mlx-swift_Cmlx.bundle, which this change did not cause).
    - next: /review. The task stays in doing.
  timestamp: 2026-10-07T12:39:22.180108+00:00
position_column: doing
position_ordinal: '80'
title: 'Model: ToolCallEntry exposes the ACP toolCallId, and SessionModel finds a tool call entry by it'
---
## What

AgentViewKit must find the row of a tool call by the ACP `toolCallId` that the agent sends, not by its title. Now `ToolCallEntry` (`Sources/FoundationModelsACPClient/Model/ToolCallEntry.swift`) has no public `toolCallId`. The id is only inside `id` as `TranscriptEntry.ID.wire(.toolCall(ToolCallId))`, and `SessionModel.toolCallEntry(for:)` (`Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift:244`) is private.

The ACP `toolCallId` of a tool call never changes, so it is a constant, not an observed value.

1. In `ToolCallEntry.swift`:
   - Add `public nonisolated let toolCallId: ToolCallId`, with a doc comment: "The ACP id of the tool call, as the agent sent it. It never changes."
   - Change `init(wire:)` to `init(wire entry: FoundationModelsACP.SessionEntry, toolCallId: ToolCallId)`, and set the property.
2. In `Sources/FoundationModelsACPClient/Model/TranscriptEntry.swift:113`, change `case .toolCall:` to `case .toolCall(let toolCall):` and pass `toolCallId: toolCall.toolCallId` (`ToolCallUpdate.toolCallId`, FoundationModelsACP `Generated/Models9.generated.swift:57`).
3. In `SessionModel+Pending.swift`, make `toolCallEntry(for:)` public as `public func toolCallEntry(for toolCallId: ToolCallId) -> ToolCallEntry?`, with a doc comment. It reads `wireEntries`, so the lookup costs no scan of `transcript`. It gives `nil` before the agent adds the tool call, and after a transcript reset until the replay adds it again.

## Acceptance Criteria

- [x] A tool call entry that a `tool_call` update makes has `toolCallId` equal to the `toolCallId` of the update.
- [x] Later updates for the same tool call keep the same `toolCallId` and the same object.
- [x] `session.toolCallEntry(for: id)` gives that object, and `nil` for an id that the agent did not send.
- [x] After a resume replay, `toolCallEntry(for:)` gives the new object of the replayed tool call.
- [x] `swift build` gives no new warning.

## Tests

- Add tests to `Tests/FoundationModelsACPClientTests/Model/SessionModelFoldTests.swift`, with `SessionModelFixtures` and `SessionUpdateFixtures` (fold `tool_call` and `tool_call_update` updates through `apply(_:)` with `coalescingCadence: .zero`). No sleeps.
  - `aToolCallEntryHasTheToolCallIdOfTheAgent`
  - `aToolCallUpdateKeepsTheToolCallId`
  - `toolCallEntryForAnIdFindsTheEntry`
  - `toolCallEntryForAnUnknownIdIsNil`
  - `toolCallEntryForAnIdFindsTheReplayedEntryAfterAReset`
- Command: `swift test --filter SessionModelFoldTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [x] Write the five failing tests.
- [x] Add `ToolCallEntry.toolCallId` and pass it from `TranscriptEntry(wire:)`.
- [x] Make `SessionModel.toolCallEntry(for:)` public, with its doc comment.
