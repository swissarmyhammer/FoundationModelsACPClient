---
assignees:
- claude-code
depends_on:
- 01M3YR05Z28B6DMHMSRK03QP9Q
position_column: todo
position_ordinal: '8280'
title: 'Model: SessionModel folds updates through the engine into entries and last-value state'
---
## What
New `@MainActor @Observable public final class SessionModel` in `Sources/FoundationModelsACPClient/Model/SessionModel.swift`. This task covers the fold only (no coalescing, no stream, no prompt, no pending requests).

- [ ] Hold the FoundationModelsACP merge engine. An internal `apply(_ update: SessionUpdate)` gives the update to the engine and reads its `Change`: `entryAdded(index, entry)` inserts a new entry object into `transcript`; `entryChanged(index, entry)` calls `update(from:)` on that one object only; each state case writes its last-value property.
- [ ] Public read-only state: `sessionId`, `transcript: [TranscriptEntry]`, `availableCommands: [AvailableCommand]?` (nil = not reported), `configOptions`, `usage`, `agentState` (running / idle(stopReason) / requiresAction), `sessionInfo`. `StopReason.unknown(String)` stays raw (for example `_truncated`).
- [ ] Unknown `SessionUpdate` cases and unknown content blocks become `unknown` entries with the raw JSON. Plan entries keep their first position. Terminal chunks append bytes and an `output` snapshot replaces them (the engine supplies the rule; this model reflects it).
- [ ] Internal `seed(availableCommands:configOptions:)` for the new / resume response values. A nil list leaves `availableCommands` nil.

## Acceptance Criteria
- [ ] Every `SessionUpdate` case lands in `transcript` or in a last-value property; none is dropped.
- [ ] A chunk for entry A causes no observation change on entry B.
- [ ] `availableCommands` is nil before any report, and `[]` after an empty `available_commands_update`.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/SessionModelFoldTests.swift` (reuse `SessionUpdateFixtures.swift`): one test per update case; `unknownUpdateBecomesUnknownEntry`; `truncatedStopReasonStaysRaw`; `planReplaceKeepsPosition`; `terminalChunkAppendsBytes`; `terminalOutputSnapshotReplacesBytes`; `seedWithNilCommandsLeavesNil`; `seedWithCommandsSetsThem`; per-entry observation isolation with `withObservationTracking`.
- [ ] `swift test --filter SessionModelFoldTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.