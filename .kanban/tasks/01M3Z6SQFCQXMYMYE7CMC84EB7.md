---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m40vyfktgnnxetmpe6y4thra
  text: |-
    UPSTREAM READY (foundationmodelsacp-c7, 2026-10-03): ^zj1wfec and ^k55fg8a are on FoundationModelsACP main at 60854b6. Update the pin to 60854b6 or later. Final names:

    Engine:
    - `SessionEntry.ID.compaction(Unstable.CompactionId)`; `SessionEntry.Kind.compaction(SessionEntry.Compaction)`.
    - `SessionEntry.Compaction` (Hashable, Sendable): `compactionId: Unstable.CompactionId`, `status: Unstable.CompactionStatus`, `summary: [ContentBlock]`, `error: PatchField<String>`, `meta: PatchField<JSONValue>`, `static let unreportedStatus = .unknown("_unreported")`.
    - `SessionMergeEngine.Change.notice(Unstable.Notice)`: `apply` returns it; the engine does NOT store it and does NOT replay it.

    Behavior:
    - The first `compaction_update` for an ID adds the entry at the END (`entryAdded`). Its position then stays fixed.
    - Later updates fold onto it (`entryChanged`). `summary: []` and `null` both clear the summary.
    - A `compaction_summary_chunk` appends one block (`entryChanged`).
    - A chunk that comes BEFORE any update creates the entry with `status == SessionEntry.Compaction.unreportedStatus`. Show that status as "no status yet".
    - A compaction never changes earlier entries. A malformed known payload becomes an `unknown` entry.
    - `transcriptUpdates` replays each compaction as one `compaction_update`.

    Types (namespace `Unstable`):
    - `CompactionStatus` (`.inProgress`, `.completed`, `.failed`, `.cancelled`, `.unknown(String)`).
    - `Notice` (`severity`, `title`, `description: String?`, `meta`); `NoticeSeverity` (`.info`, `.warning`, `.error`, `.unknown(String)`).
    - `Unstable.SessionUpdate(_ update: SessionUpdate) throws -> Self?` reads a raw update (use it in `updateTap()` consumers if needed). `SessionUpdate(_: Unstable.SessionUpdate) throws` encodes it back.

    Changes to this task:
    - `CompactionEntry.summary` is `[ContentBlock]`, not text.
    - `CompactionEntry.status` keeps `unreportedStatus` and offers `hasReportedStatus: Bool`.
    - `SessionNotice` wraps `Unstable.Notice` (severity, title, description, meta) and adds an id and an arrival time.
    - Add tests for: a chunk before any update (unreported status), `summary: []` and `null` both clear, a malformed payload becomes an `unknown` entry, and a replay gives the same entry.
  timestamp: 2026-10-03T12:31:13.018321+00:00
- actor: claude-code
  id: 01m419ecdwewgab40fevpn0ese
  text: |-
    Research (implement):
    - Pin: `swift package update FoundationModelsACP` (root) and `swift package --package-path IntegrationTests update FoundationModelsACP` (the `--package-path` flag must come before `update`; after it, SwiftPM says "Unknown option"). Both Package.resolved files now pin 60854b658d24b2c81c991c28880f5733448287ed. All final names are in `.build/checkouts/FoundationModelsACP/Sources`.
    - The new pin breaks the build in one place: `SessionMergeEngine.Change.notice` makes the switches in `SessionModel+Coalescing.swift` (`changedEntry`, `replacingEntry`) and `SessionModel.reflect` non-exhaustive. `SessionEntry.Kind.compaction` makes `TranscriptEntry.init(wire:)` non-exhaustive.
    - The engine adds a compaction entry at the end, folds later updates onto it, and appends summary chunks. A chunk before any update gives `status == SessionEntry.Compaction.unreportedStatus`. A malformed known payload becomes `.unknown`. `transcriptUpdates` replays a compaction as one `compaction_update`; a notice is never stored or replayed.
    - The injected clock is `any Clock<Duration>`, which has no wall-clock date. Plan: `SessionNotice.arrivalTime` is a `Duration`: the elapsed time on the injected clock from the model init to the arrival.
    - `updateTap()` already yields every raw update before the coalescer, so compaction and notice updates reach it with no change. A test keeps that contract.
  timestamp: 2026-10-03T16:27:05.532141+00:00
- actor: claude-code
  id: 01m41a3x04pvr16n64byp7gtsb
  text: |-
    Implementation notes:
    - `CompactionEntry` is in its own file. It keeps `status` as `Unstable.CompactionStatus` (the `unreportedStatus` value stays) and adds `hasReportedStatus`. `summary` is `[ContentBlock]`, `error` and `meta` are `PatchField.currentValue`. `init(wire:compaction:)` takes the merged compaction from `TranscriptEntry.init(wire:)`, so `compactionId` is a `let`.
    - `SessionNotice` wraps `Unstable.Notice` (severity, title, description, meta) and adds `id: UUID` and `arrivalTime: Duration`. The injected clock is `any Clock<Duration>` and has no wall-clock date, so `arrivalTime` is the time on that clock from the model init to the arrival. A private generic `makeElapsedTime(on:)` opens the existential clock.
    - `beginReplay` clears `notices` always (also for `replayFrom: nil`), because the orchestrator said "`beginReplay` and `markClosed` must clear `notices`". `markClosed` clears them too.
    - Pin fixes: `.notice` added to the switches in `SessionModel+Coalescing.swift` and to the test helper `SessionMergeEngine.Change.entry` in `TranscriptEntryTests.swift`.
    - Shared test helpers added to `SessionModelFixtures.swift`: `compactionId`, `compactionUpdate`, `compactionChunk`, `noticeUpdate`, and `SessionModel.applyEach(_:)`. `TranscriptEntryTestSupport.swift` got the `compaction` accessor.
    - TDD: RED for compaction was a compile failure (no entry class for the compaction kind); RED for notices was a compile failure (no `notices`, no `dismissNotice`). `aStatusChangeWritesOnlyTheStatus` and `theUpdateTapGivesTheRawNoticeAndCompactionUpdates` passed at once, because the shared `assign` and the existing tap already give that behavior; they stay as contract tests.
    - Discovery: the first full `swift test` run had 1 failure in `AgentProcessTeardownTests.teardownReapsAnAgentTheGroupKillMissedOnceItsStdinCloses` (`!StdioChild.isInProcessTable`). It passed alone and in the next full run. This change does not touch that code. New task ^h5z930j records the timing flake.
  timestamp: 2026-10-03T16:38:50.628445+00:00
- actor: claude-code
  id: 01m41a4103gx2hecnm61e4e1cc
  text: |-
    ### implement — changed
    - evidence: pin FoundationModelsACP 60854b6 in Package.resolved and IntegrationTests/Package.resolved (both git-ignored). New: Sources/FoundationModelsACPClient/Model/CompactionEntry.swift, Sources/FoundationModelsACPClient/Model/SessionNotice.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelCompactionTests.swift (12 tests), Tests/FoundationModelsACPClientTests/Model/SessionModelNoticeTests.swift (9 tests). Changed: Model/SessionModel.swift, Model/SessionModel+Stream.swift, Model/SessionModel+Coalescing.swift, Model/TranscriptEntry.swift, Tests Model/SessionModelFixtures.swift, Model/TranscriptEntryTestSupport.swift, Model/TranscriptEntryTests.swift. `swift build`: complete, only the accepted MLX "missing creator for mutated node" warning. `swift test`: 414 tests in 35 suites passed (an earlier full run had 1 failure in the unrelated flaky AgentProcessTeardownTests; see ^h5z930j). `swift build --package-path IntegrationTests`: complete. `swift test --package-path IntegrationTests`: 103 tests in 14 suites passed. Only warnings: permitted `SessionUpdateAggregator` deprecations.
    - next: /review
  timestamp: 2026-10-03T16:38:54.723893+00:00
- actor: claude-code
  id: 01m41ab6dpx927y50npt7zh1p1
  text: |-
    ### test — green
    - evidence: swift build x2 (root): complete, 0 new warnings. swift test x2 (root): 414 tests in 35 suites passed, 0 failed, 0 skipped. swift build --package-path IntegrationTests: complete. swift test --package-path IntegrationTests: 103 tests in 14 suites passed, 0 failed, 0 skipped. FoundationModelsACP pin 60854b6.
    - warnings: only the accepted mlx-swift warning (missing creator for mutated node, mlx-swift_Cmlx.bundle).
    - known issue: AgentProcessTeardownTests timing failure (task ^h5z930j) did not happen.
    - next: review
  timestamp: 2026-10-03T16:42:49.654834+00:00
- actor: claude-code
  id: 01m41abh9kxv52hze1419848fn
  text: |-
    ### commit — changed
    - evidence: feat(model): add compaction entries and transient notices to SessionModel. Tests: swift test 414/414 two times, IntegrationTests 103/103. Needs FoundationModelsACP revision 60854b6.
    - next: review
  timestamp: 2026-10-03T16:43:00.787442+00:00
- actor: claude-code
  id: 01m41aj6zsr20731n3sb6jq56w
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 61ae75e). 11 files reviewed, 7 validator runs, 0 failed. Counts: 0 findings, 0 confirmed, 0 refuted. No earlier Review Findings sections. Excluded by .reviewignore: 6 files in .kanban/.
    - next: none. The task moved to done.
  timestamp: 2026-10-03T16:46:39.609795+00:00
- actor: claude-code
  id: 01m41ajdy13za55yw59ypa4kzq
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 11 files; pin FoundationModelsACP 60854b6
    - test: green — swift test 414/414 x2, IntegrationTests 103/103
    - commit: 61ae75e feat(model): add compaction entries and transient notices to SessionModel
    - review: clean — task moved to done
  timestamp: 2026-10-03T16:46:46.721996+00:00
depends_on:
- 01M3YR0FJ4Z55VAXKXQ3KAM7GW
- 01M3YRC0ERS5FADQYB965X5KJR
position_column: done
position_ordinal: c180
title: 'Model: compaction transcript entry and transient notices in SessionModel'
---
## What
**Step 0, before any other step:** update FoundationModelsACP (`swift package update FoundationModelsACP`) and check for `SessionEntry.ID.compaction` and `Change.notice` in `.build/checkouts/FoundationModelsACP/Sources`. If either is missing, STOP: restore the old pin in `Package.resolved` (the file is git-ignored; write the old revision back by hand and run `swift package resolve`), add the comment "upstream not ready" to this task, and report `stuck`. Start only when foundationmodelsacp-c7 reports ^k55fg8a (unstable `compaction_update`, `compaction_summary_chunk`, `notice` types) and ^zj1wfec (engine compaction entry and `Change.notice`) on main. Use the final names from its message (a comment on this task, when it arrives).

Decision of the user (via foundationmodelsacp-c7, 2026-10-02): agent compaction changes only the model context. The ACP transcript keeps the full history; nothing is removed from `transcript`.

- [x] New entry class `CompactionEntry` in `Sources/FoundationModelsACPClient/Model/TranscriptEntry.swift` (or its own file): `compactionId`, `status` (`inProgress`, `completed`, `failed`, `cancelled`, plus raw unknown values), `summary` text, `error`, `meta`, `origin = .wire`. `update(from:)` writes only changed fields, as the other entry classes do.
- [x] `SessionModel.apply` maps `entryAdded` / `entryChanged` for the compaction kind to this class. The entry keeps its first position; summary chunks append (the engine supplies the rule). A compaction never changes earlier entries.
- [x] Notices: `Change.notice(...)` is not stored in the engine and is not replayed. `SessionModel` exposes `public private(set) var notices: [SessionNotice]` (id, text or payload, `meta`, arrival time from the injected clock) and `public func dismissNotice(_ id:)`. A notice is transient: it never goes into `transcript`, and `beginReplay` / `markClosed` clear the list.
- [x] `updateTap()` still yields the raw `compaction_*` and `notice` updates, so acp-client sees them.

## Acceptance Criteria
- [x] A `compaction_update` adds one compaction entry; later updates and summary chunks change only that entry; entries before it are unchanged.
- [x] A `notice` adds one item to `notices` and nothing to `transcript`; `dismissNotice` removes it.
- [x] A resume replay does not bring back a notice.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/SessionModelCompactionTests.swift`: compaction add, status changes, summary chunk append, earlier entries unchanged (`withObservationTracking` on an earlier entry), failed and cancelled status.
- [x] New `Tests/FoundationModelsACPClientTests/Model/SessionModelNoticeTests.swift`: notice add, dismiss, cleared on replay and on close, not in `transcript`.
- [x] `swift test --filter 'SessionModelCompactionTests|SessionModelNoticeTests'` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.