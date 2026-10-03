---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m410t38gm2m83hkpcy6b03ae
  text: |-
    Implementation notes (2026-10-03):
    - Pin: FoundationModelsACP 284e002. At this revision, `SessionEntry.Kind` has no `compaction` case and `SessionMergeEngine.Change` has no `notice` case (searched `.build/checkouts/FoundationModelsACP/Sources/FoundationModelsACP/Session/`). So the switch over `Change` has the 7 cases only, and no placeholder for ^mc84eb7 was necessary. When the pin moves to 60854b6 or later, the switch in `SessionModel.reflect(_:)` and in `TranscriptEntry.init(wire:)` stops compiling; ^mc84eb7 adds those cases.
    - `entryChanged` finds the object by the engine identity (`wireEntries: [FoundationModelsACP.SessionEntry.ID: TranscriptEntry]`), not by the engine index. Reason: later tasks put local entries (pending user message, error entries) in `transcript`, so the engine index and the transcript index will differ. A missing object gives `assertionFailure` plus an error log, and the model stays unchanged.
    - New internal `TranscriptEntry.update(from:)` in TranscriptEntry.swift dispatches to the one object. The `.error` case calls `recordKindMismatch()`, because the engine never changes a local error entry.
    - `seed(availableCommands:configOptions:)` builds a `NewSessionResponse` and calls `engine.seed(from:)`, so the engine rule applies: a nil OR EMPTY command list leaves `availableCommands` as it is (the engine treats both as "no initial commands"). Only an `available_commands_update` with `[]` gives `[]`.
    - "Unknown content blocks": the engine keeps a `ContentBlock.unknown(type, json)` raw inside the content of its message entry; it does not make a separate entry. The model reflects that rule (test `unknownContentBlockStaysRawInItsMessage`).
    - `agentState` is the wire type `StateUpdate?` (running / idle(IdleStateUpdate with stopReason) / requiresAction / unknown), so `StopReason.unknown("_truncated")` stays raw with no mapping code.
    - Test support: the `TranscriptEntry` kind accessors and `observationFires` moved from TranscriptEntryTests.swift (fileprivate/private) to the new shared Tests/FoundationModelsACPClientTests/Model/TranscriptEntryTestSupport.swift, so the new suite does not copy them.
    - The tests are in `struct SessionModelFoldTests` (a suite). Free `@Test` functions have no suite name in their identifier, so `swift test --filter SessionModelFoldTests` would select nothing without the suite type.
    - RED evidence: `swift build --build-tests` failed with "cannot find type 'SessionModel' in scope" before the source file existed.
  timestamp: 2026-10-03T13:56:12.176767+00:00
- actor: claude-code
  id: 01m410t6nehwvstbdxg7mxkmgr
  text: |-
    ### implement — changed
    - evidence: 5 files (not committed) — new Sources/FoundationModelsACPClient/Model/SessionModel.swift; Sources/FoundationModelsACPClient/Model/TranscriptEntry.swift (internal `update(from:)` dispatch); new Tests/FoundationModelsACPClientTests/Model/SessionModelFoldTests.swift (30 tests); new Tests/FoundationModelsACPClientTests/Model/TranscriptEntryTestSupport.swift; Tests/FoundationModelsACPClientTests/Model/TranscriptEntryTests.swift (helpers moved out). `swift test --filter SessionModelFoldTests`: 30 tests in 1 suite passed. `swift build`: Build complete. `swift test`: 311 tests in 28 suites passed, 0 failed. Warnings: only the accepted MLX "missing creator for mutated node" and the permitted `SessionUpdateAggregator` deprecations in ACPSessionState.swift. FoundationModelsACP 284e002 has no compaction kind and no `Change.notice`, so nothing for ^mc84eb7 was added.
    - next: /review
  timestamp: 2026-10-03T13:56:15.662764+00:00
- actor: claude-code
  id: 01m410yxyq83gg3agq2v0z5cdv
  text: |-
    ### test — green
    - evidence: swift build (complete); swift test (311 tests in 28 suites passed, 0 failed, 0 skipped); swift build --package-path IntegrationTests (complete); swift test --package-path IntegrationTests (103 tests in 14 suites passed, 0 failed, 0 skipped). Warnings: only the accepted mlx-swift bundle warning and the SessionUpdateAggregator deprecations.
    - next: review
  timestamp: 2026-10-03T13:58:50.583955+00:00
- actor: claude-code
  id: 01m410z9t8wxzegrnq1skcabsk
  text: |-
    ### commit — changed
    - evidence: feat(model): add SessionModel that folds updates through the merge engine. Tests: swift test 311/311, IntegrationTests 103/103. One local commit, not pushed.
    - next: review
  timestamp: 2026-10-03T13:59:02.728774+00:00
- actor: claude-code
  id: 01m4119rwd7ckn12796t9eetgn
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 07b50c3). 5 files reviewed; 4 .kanban files not reviewed (.reviewignore). counts: findings 0, confirmed 0, refuted 2, attempted 7, failed 0, skipped 0. The task had no prior Review Findings sections.
    - next: none. The task moved to done.
  timestamp: 2026-10-03T14:04:45.837400+00:00
- actor: claude-code
  id: 01m411a16swgc5nexyfde64xbp
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — SessionModel.swift (new), TranscriptEntry.swift, 3 test files; 30 new tests
    - test: green — swift test 311/311, IntegrationTests 103/103; only accepted warnings
    - commit: 07b50c3 feat(model): add SessionModel that folds updates through the merge engine
    - review: clean — task moved to done
  timestamp: 2026-10-03T14:04:54.361439+00:00
depends_on:
- 01M3YR05Z28B6DMHMSRK03QP9Q
position_column: done
position_ordinal: bc80
title: 'Model: SessionModel folds updates through the engine into entries and last-value state'
---
## What
New `@MainActor @Observable public final class SessionModel` in `Sources/FoundationModelsACPClient/Model/SessionModel.swift`. This task covers the fold only (no coalescing, no stream, no prompt, no pending requests).

- [x] Hold the FoundationModelsACP merge engine. An internal `apply(_ update: SessionUpdate)` gives the update to the engine and reads its `Change`: `entryAdded(index, entry)` inserts a new entry object into `transcript`; `entryChanged(index, entry)` calls `update(from:)` on that one object only; each state case writes its last-value property.
- [x] Public read-only state: `sessionId`, `transcript: [TranscriptEntry]`, `availableCommands: [AvailableCommand]?` (nil = not reported), `configOptions`, `usage`, `agentState` (running / idle(stopReason) / requiresAction), `sessionInfo`. `StopReason.unknown(String)` stays raw (for example `_truncated`).
- [x] Unknown `SessionUpdate` cases and unknown content blocks become `unknown` entries with the raw JSON. Plan entries keep their first position. Terminal chunks append bytes and an `output` snapshot replaces them (the engine supplies the rule; this model reflects it).
- [x] Internal `seed(availableCommands:configOptions:)` for the new / resume response values. A nil list leaves `availableCommands` nil.

## Acceptance Criteria
- [x] Every `SessionUpdate` case lands in `transcript` or in a last-value property; none is dropped.
- [x] A chunk for entry A causes no observation change on entry B.
- [x] `availableCommands` is nil before any report, and `[]` after an empty `available_commands_update`.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/SessionModelFoldTests.swift` (reuse `SessionUpdateFixtures.swift`): one test per update case; `unknownUpdateBecomesUnknownEntry`; `truncatedStopReasonStaysRaw`; `planReplaceKeepsPosition`; `terminalChunkAppendsBytes`; `terminalOutputSnapshotReplacesBytes`; `seedWithNilCommandsLeavesNil`; `seedWithCommandsSetsThem`; per-entry observation isolation with `withObservationTracking`.
- [x] `swift test --filter SessionModelFoldTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.