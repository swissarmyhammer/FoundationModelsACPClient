---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m41jnfxn4bwk12bqvrm7ezq2
  text: 'Research: `PlanUpdateContent` (upstream generated union) has two cases, `.items(PlanItems)` and `.unknown(String, JSONValue)`. The engine keeps the whole `PlanUpdate` on the `.plan` entry kind, so the type and payload are available in `PlanTranscriptEntry.update(from:)`. `assign(_:to:)` needs an `Equatable` value, and a tuple is not `Equatable`. Plan: add a nested `PlanTranscriptEntry.UnknownContent` struct (`type: String`, `payload: JSONValue`, `Hashable`, `Sendable`) and an `unknownContent: UnknownContent?` property. `UnknownEntry` keeps its fields as `type` and `raw`; the card says "the raw `JSONValue`", so the struct names the field `payload` to match the upstream case name. The old `ACPSessionState` drops plan updates of all kinds at its own switch; this change does not touch it.'
  timestamp: 2026-10-03T19:08:15.669560+00:00
- actor: claude-code
  id: 01m41jtcg6ncde21kb34zxmw4x
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPClient/Model/PlanTranscriptEntry.swift (new nested `public struct UnknownContent: Hashable, Sendable { type: String; payload: JSONValue }`, new `public internal(set) var unknownContent: UnknownContent?`, written in `update(from:)` with `assign(_:to:)` through a private static `unknownContent(of:)`), Tests/FoundationModelsACPClientTests/Model/TranscriptEntryTests.swift (new tests `planUpdateOfUnknownContentKeepsTheTypeAndThePayload` and `planUpdateOfItemsHasNoUnknownContent`; `plan.unknownContent` added to the read set of `equalTerminalPlanAndUnknownUpdatesFireNoObservation`). RED: the build failed because `unknownContent` / `UnknownContent` were missing. GREEN: `swift test --filter TranscriptEntryTests` 19/19 passed. `swift build` complete. `swift test` 477 tests in 40 suites passed. Only permitted warnings (`SessionUpdateAggregator` deprecation, MLX "missing creator for mutated node"). The old `ACPSessionState` / `SwiftUIACPClient` code was not changed.
    - next: /review
  timestamp: 2026-10-03T19:10:56.006148+00:00
- actor: claude-code
  id: 01m41jz07v786pbr1y7f3128hc
  text: |-
    ### test — green
    - evidence: swift build: complete, 0 errors. swift test: 477 tests in 40 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests: 103 tests in 14 suites passed, 0 failed, 0 skipped.
    - warnings: only the permitted ones. MLX "missing creator for mutated node". SessionUpdateAggregator deprecation in ACPSessionState.swift.
    - next: review.
  timestamp: 2026-10-03T19:13:27.291650+00:00
- actor: claude-code
  id: 01m41jzammvg02p80qdvw8fnq5
  text: |-
    ### commit — changed
    - evidence: One local commit: feat(model): keep the raw content of an unknown plan update on PlanTranscriptEntry. The sha is in the git log, on the commit that has this subject.
    - next: Review the task. Do not push.
  timestamp: 2026-10-03T19:13:37.940758+00:00
- actor: claude-code
  id: 01m41k3tfzwewds0k2qy7jyrfk
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 9fc6f32); 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed; 2 files reviewed, 4 .kanban files ignored by .reviewignore.
    - next: none. The task moved to done.
  timestamp: 2026-10-03T19:16:05.247856+00:00
- actor: claude-code
  id: 01m41k4119qxank7h6a77nhk1g
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files (PlanTranscriptEntry.swift, TranscriptEntryTests.swift)
    - test: green — swift test 477/477, IntegrationTests 103/103
    - commit: 9fc6f32 feat(model): keep the raw content of an unknown plan update on PlanTranscriptEntry
    - review: clean — task moved to done
  timestamp: 2026-10-03T19:16:11.945836+00:00
depends_on:
- 01M3YR05Z28B6DMHMSRK03QP9Q
position_column: done
position_ordinal: c880
title: 'Model: keep the raw content of a plan update of unknown type on PlanTranscriptEntry'
---
## What
`PlanTranscriptEntry` (Sources/FoundationModelsACPClient/Model/PlanTranscriptEntry.swift) shows only `planId`, `entries` and `meta`. For `PlanUpdateContent.unknown(type, payload)`, `entries` is `[]`, and the type and the raw payload are not on the object. A UI cannot show such a plan, so the data is dropped at the model layer (the engine keeps it).

- [x] Add read-only `unknownContent` (the type `String` and the raw `JSONValue`, or `nil` for item content) to `PlanTranscriptEntry`, written in `update(from:)` with `assign(_:to:)`.

## Acceptance Criteria
- [x] A plan update with unknown content gives a plan entry with that type and payload.
- [x] A plan update with items gives `unknownContent == nil`.

## Tests
- [x] Add the two cases to `Tests/FoundationModelsACPClientTests/Model/TranscriptEntryTests.swift`.
- [x] `swift test --filter TranscriptEntryTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.