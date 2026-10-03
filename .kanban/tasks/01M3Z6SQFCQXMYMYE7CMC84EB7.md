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
depends_on:
- 01M3YR0FJ4Z55VAXKXQ3KAM7GW
- 01M3YRC0ERS5FADQYB965X5KJR
position_column: todo
position_ordinal: '9180'
title: 'Model: compaction transcript entry and transient notices in SessionModel'
---
## What
**Step 0, before any other step:** update FoundationModelsACP (`swift package update FoundationModelsACP`) and check for `SessionEntry.ID.compaction` and `Change.notice` in `.build/checkouts/FoundationModelsACP/Sources`. If either is missing, STOP: restore the old pin in `Package.resolved` (the file is git-ignored; write the old revision back by hand and run `swift package resolve`), add the comment "upstream not ready" to this task, and report `stuck`. Start only when foundationmodelsacp-c7 reports ^k55fg8a (unstable `compaction_update`, `compaction_summary_chunk`, `notice` types) and ^zj1wfec (engine compaction entry and `Change.notice`) on main. Use the final names from its message (a comment on this task, when it arrives).

Decision of the user (via foundationmodelsacp-c7, 2026-10-02): agent compaction changes only the model context. The ACP transcript keeps the full history; nothing is removed from `transcript`.

- [ ] New entry class `CompactionEntry` in `Sources/FoundationModelsACPClient/Model/TranscriptEntry.swift` (or its own file): `compactionId`, `status` (`inProgress`, `completed`, `failed`, `cancelled`, plus raw unknown values), `summary` text, `error`, `meta`, `origin = .wire`. `update(from:)` writes only changed fields, as the other entry classes do.
- [ ] `SessionModel.apply` maps `entryAdded` / `entryChanged` for the compaction kind to this class. The entry keeps its first position; summary chunks append (the engine supplies the rule). A compaction never changes earlier entries.
- [ ] Notices: `Change.notice(...)` is not stored in the engine and is not replayed. `SessionModel` exposes `public private(set) var notices: [SessionNotice]` (id, text or payload, `meta`, arrival time from the injected clock) and `public func dismissNotice(_ id:)`. A notice is transient: it never goes into `transcript`, and `beginReplay` / `markClosed` clear the list.
- [ ] `updateTap()` still yields the raw `compaction_*` and `notice` updates, so acp-client sees them.

## Acceptance Criteria
- [ ] A `compaction_update` adds one compaction entry; later updates and summary chunks change only that entry; entries before it are unchanged.
- [ ] A `notice` adds one item to `notices` and nothing to `transcript`; `dismissNotice` removes it.
- [ ] A resume replay does not bring back a notice.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/SessionModelCompactionTests.swift`: compaction add, status changes, summary chunk append, earlier entries unchanged (`withObservationTracking` on an earlier entry), failed and cancelled status.
- [ ] New `Tests/FoundationModelsACPClientTests/Model/SessionModelNoticeTests.swift`: notice add, dismiss, cleared on replay and on close, not in `transcript`.
- [ ] `swift test --filter 'SessionModelCompactionTests|SessionModelNoticeTests'` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.