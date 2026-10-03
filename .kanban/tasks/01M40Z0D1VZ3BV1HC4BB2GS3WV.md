---
assignees:
- claude-code
depends_on:
- 01M3YR05Z28B6DMHMSRK03QP9Q
position_column: todo
position_ordinal: '9380'
title: 'Model: keep the raw content of a plan update of unknown type on PlanTranscriptEntry'
---
## What
`PlanTranscriptEntry` (Sources/FoundationModelsACPClient/Model/PlanTranscriptEntry.swift) shows only `planId`, `entries` and `meta`. For `PlanUpdateContent.unknown(type, payload)`, `entries` is `[]`, and the type and the raw payload are not on the object. A UI cannot show such a plan, so the data is dropped at the model layer (the engine keeps it).

- [ ] Add read-only `unknownContent` (the type `String` and the raw `JSONValue`, or `nil` for item content) to `PlanTranscriptEntry`, written in `update(from:)` with `assign(_:to:)`.

## Acceptance Criteria
- [ ] A plan update with unknown content gives a plan entry with that type and payload.
- [ ] A plan update with items gives `unknownContent == nil`.

## Tests
- [ ] Add the two cases to `Tests/FoundationModelsACPClientTests/Model/TranscriptEntryTests.swift`.
- [ ] `swift test --filter TranscriptEntryTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.