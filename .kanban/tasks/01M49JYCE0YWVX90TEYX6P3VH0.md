---
assignees:
- claude-code
position_column: todo
position_ordinal: 8c80
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

- [ ] A tool call entry that a `tool_call` update makes has `toolCallId` equal to the `toolCallId` of the update.
- [ ] Later updates for the same tool call keep the same `toolCallId` and the same object.
- [ ] `session.toolCallEntry(for: id)` gives that object, and `nil` for an id that the agent did not send.
- [ ] After a resume replay, `toolCallEntry(for:)` gives the new object of the replayed tool call.
- [ ] `swift build` gives no new warning.

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

- [ ] Write the five failing tests.
- [ ] Add `ToolCallEntry.toolCallId` and pass it from `TranscriptEntry(wire:)`.
- [ ] Make `SessionModel.toolCallEntry(for:)` public, with its doc comment.
