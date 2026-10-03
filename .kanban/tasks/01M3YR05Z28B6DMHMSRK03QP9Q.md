---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m40ydrancgbqs58g9m7pqw0d
  text: |-
    Research (2026-10-03), FoundationModelsACP 284e002:
    - Upstream `FoundationModelsACP.SessionEntry` has NO public init and `kind` is `public internal(set)`. Tests cannot build an engine entry by hand. They must get it from `SessionMergeEngine.apply(_:)` (`Change.entryAdded/entryChanged`).
    - `PatchField.folded(onto:)` is internal upstream. `resolved(onto:)` (collections) and `init(optional:)` are public. To expose a patch field as an optional, this module needs its own small accessor.
    - Upstream `PlanEntry` is the schema type for one plan item. Our plan class therefore cannot be named `PlanEntry`. Upstream has no `ToolCallEntry`, `TerminalEntry`, `UserMessageEntry`, `ThoughtEntry` names.
    - The engine has no error kind. An error entry is local only (task 7xv14k8 makes it). It has no `update(from:)`, because no engine value exists for it.
    - JSON-RPC error code type: `ErrorCode` (schema enum, `wireValue: Int`, `.unknown(Int)`). Error data: `JSONValue?` (as in `ACPError`).
    - `linkedElicitationIDs`: the local elicitation identity is `PendingElicitation.ID` (UUID).
    - The old `ACPSessionState` exposes the full `AccumulatedTerminal` (command, cwd, exitStatus, output). The terminal class keeps command and cwd too, so the terminal display keeps parity.
    - Design: `TranscriptEntry` enum (Identifiable, Sendable) of the class objects. `TranscriptEntry.ID` = `.wire(FoundationModelsACP.SessionEntry.ID)` or `.local(UUID)`; `origin` comes from the id, so a local user message keeps `.local` and the same id after the link. One `@MainActor @Observable public final class` for each kind. Shared change-only write helper in an internal protocol extension, so the classes keep no duplicated logic.
  timestamp: 2026-10-03T13:14:30.613556+00:00
- actor: claude-code
  id: 01m40z06qj16s00cwtq71dg6t5
  text: |-
    Implementation notes (2026-10-03):
    - RED: `swift test --filter TranscriptEntryTests` failed to compile ("cannot find type 'TranscriptEntry' in scope"). GREEN after the classes: 16 tests pass.
    - One test expectation was wrong, not the code: after a plan update with no `_meta`, the engine KEEPS the old `_meta` (SessionMergeEngine.updatePlan: `incoming.meta ?? plan.meta`). The test now expects the kept value, with a comment that names the engine rule.
    - Discovery: the `@Observable` macro of this toolchain (Swift 6.4) already skips the notification when an `Equatable` property gets an equal value. Measured: with the equality guard removed from `assign(_:to:)`, the two equal-value observation tests still passed. So no test can show RED for the guard. The guard stays, because the card asks for "no write when a value is equal" and the guard keeps that contract without the macro behavior. The doc comment of `assign(_:to:)` says this.
    - Design: 8 classes, one for each kind (`UserMessageEntry`, `AgentMessageEntry`, `ThoughtEntry`, `ToolCallEntry`, `TerminalEntry`, `PlanTranscriptEntry`, `UnknownEntry`, `ErrorEntry`), one file each, because the total is more than 400 lines. The shared logic is in `TranscriptEntry.swift`: public protocol `ObservableTranscriptEntry` (gives `origin` from the id), internal `assign(_:to:)` and `recordKindMismatch()`, internal protocol `MessageTranscriptEntry` (one `apply(_:)` for the three message kinds), and `PatchField.currentValue`.
    - `update(from:)` with an engine entry of another kind: `assertionFailure` plus an error log under `ACPClientTelemetry.logLabel` (the log has the class name only, no content). The engine identity tells the kind, so a caller that finds the object by identity does not get there.
    - `messageId` is `MessageId?` on the three message classes, as the card says. The local user message `init(content:meta:)` and `ErrorEntry.init(code:message:data:)` are internal; task ^7xv14k8 (SessionModel prompt) uses them.
    - Gap for a later task: a plan update with unknown content (`PlanUpdateContent.unknown`) gives `entries == []`; the raw content is not kept on `PlanTranscriptEntry`. The card asks only for `planId` and `entries`.
  timestamp: 2026-10-03T13:24:35.186707+00:00
- actor: claude-code
  id: 01m40z0hdes4zvv6p5dzkbz3fh
  text: |-
    ### implement — changed
    - evidence: 10 new files (not committed): Sources/FoundationModelsACPClient/Model/{TranscriptEntry, UserMessageEntry, AgentMessageEntry, ThoughtEntry, ToolCallEntry, TerminalEntry, PlanTranscriptEntry, UnknownEntry, ErrorEntry}.swift, Tests/FoundationModelsACPClientTests/Model/TranscriptEntryTests.swift. `swift test --filter TranscriptEntryTests` -> 16 tests pass. `swift test` -> 280 tests in 27 suites passed, 0 failed (was 264). `swift build` -> Build complete; warnings: only the accepted MLX "missing creator for mutated node" and the permitted `SessionUpdateAggregator` deprecations (ACPSessionState.swift). No warning from the new files. Package.resolved not changed.
    - new task: ^b2gs3wv (keep the raw content of a plan of unknown type).
    - next: /review
  timestamp: 2026-10-03T13:24:46.126252+00:00
- actor: claude-code
  id: 01m40zejffcq0z5agmatgdkmk7
  text: |-
    ### test — green
    - evidence: `swift build` complete. `swift test` first run: 280 tests, 1 failure: "a successful prompt gives one count and one duration, and no error" (ClientRequestMetricsTests.swift:85). Cause: a race. The turn ended on `idle` and cancelled the prompt call before its answer reached the client, so a `cancelled` error counter was recorded. Not in the code of this task (Model/). Fix: `TracedSessionHarness` takes a `deferredScript`. The test now sends `idle` behind a gate and opens the gate only after the prompt request counter shows the answer arrived. Filtered run: 4 passed. Final `swift test`: 280 tests in 27 suites passed, 0 failures, 0 skipped. `swift build --package-path IntegrationTests` complete. `swift test --package-path IntegrationTests`: 103 tests in 14 suites passed, 0 skipped.
    - warnings: only the accepted ones (mlx "missing creator for mutated node", mlx-swift C++17-extension warnings, SessionUpdateAggregator deprecations).
    - next: review
  timestamp: 2026-10-03T13:32:25.967344+00:00
- actor: claude-code
  id: 01m40zf954cpa2b5ch6f4prw77
  text: |-
    ### commit — changed
    - evidence: feat(model): add observable transcript entry classes, 18 files (commit sha in git log; local only, not pushed)
    - next: review
  timestamp: 2026-10-03T13:32:49.188077+00:00
depends_on:
- 01M3YQZVC527493KZJC81S5J74
position_column: doing
position_ordinal: '80'
title: 'Model: add the observable transcript entry classes'
---
## What
Add one `@MainActor @Observable` class for each transcript entry kind, so that a streamed chunk redraws only its own row. New file `Sources/FoundationModelsACPClient/Model/TranscriptEntry.swift` (split per kind if it is more than 400 lines).

- [x] `TranscriptEntry`: an enum or a protocol with a stable `id` (`Hashable`, `Sendable`) for `ForEach`. Kinds: `userMessage`, `agentMessage`, `thought`, `toolCall`, `terminal`, `plan`, `unknown`, `error`. The `id` of an object never changes, also when a local user message gets its `messageId`.
- [x] Each entry has `origin: EntryOrigin` (`.wire` / `.local`) and `meta` (`_meta`, folded with the engine's patch rules).
- [x] Message / thought entries: `content: [ContentBlock]`, `messageId: MessageId?` (nil for a local user message until it is linked). User-message entries also have `sendState: SendState` (`.pending`, `.sent`, `.failed`); a wire user message is `.sent`.
- [x] Tool-call entry: the full `ToolCallUpdate` fields (`name`, `title`, `kind`, `status`, `content`, `locations`, `rawInput`, `rawOutput`) and `linkedElicitationIDs`. Terminal entry: `bytes: Data`, computed `text` (lossy UTF-8), exit status. Plan entry: `planId`, `entries: [PlanEntry]`. Unknown entry: `type: String`, `raw: JSONValue`. Error entry: `code`, `message`, `data: JSONValue?`.
- [x] An internal `update(from:)` on each class that takes the engine's entry value and writes only the fields that changed (no write when a value is equal), so that Observation does not invalidate rows that did not change.

The engine (from FoundationModelsACP) owns the merge rules. These classes keep no merge rules of their own.

## Acceptance Criteria
- [x] Each entry kind of section C of the design has a class with the fields above.
- [x] `update(from:)` with an equal value causes no observation change.
- [x] Setting `messageId` and `sendState` on a local user message does not change its `id`.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/TranscriptEntryTests.swift`: a test for each kind that `update(from:)` copies the fields; a `withObservationTracking` test that an equal value does not fire `onChange`; a test that terminal `text` replaces bad UTF-8 bytes; a stable-`id` test for the local user message.
- [x] `swift test --filter TranscriptEntryTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.