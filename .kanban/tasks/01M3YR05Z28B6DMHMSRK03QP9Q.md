---
assignees:
- claude-code
depends_on:
- 01M3YQZVC527493KZJC81S5J74
position_column: todo
position_ordinal: '8180'
title: 'Model: add the observable transcript entry classes'
---
## What
Add one `@MainActor @Observable` class for each transcript entry kind, so that a streamed chunk redraws only its own row. New file `Sources/FoundationModelsACPClient/Model/TranscriptEntry.swift` (split per kind if it is more than 400 lines).

- [ ] `TranscriptEntry`: an enum or a protocol with a stable `id` (`Hashable`, `Sendable`) for `ForEach`. Kinds: `userMessage`, `agentMessage`, `thought`, `toolCall`, `terminal`, `plan`, `unknown`, `error`. The `id` of an object never changes, also when a local user message gets its `messageId`.
- [ ] Each entry has `origin: EntryOrigin` (`.wire` / `.local`) and `meta` (`_meta`, folded with the engine's patch rules).
- [ ] Message / thought entries: `content: [ContentBlock]`, `messageId: MessageId?` (nil for a local user message until it is linked). User-message entries also have `sendState: SendState` (`.pending`, `.sent`, `.failed`); a wire user message is `.sent`.
- [ ] Tool-call entry: the full `ToolCallUpdate` fields (`name`, `title`, `kind`, `status`, `content`, `locations`, `rawInput`, `rawOutput`) and `linkedElicitationIDs`. Terminal entry: `bytes: Data`, computed `text` (lossy UTF-8), exit status. Plan entry: `planId`, `entries: [PlanEntry]`. Unknown entry: `type: String`, `raw: JSONValue`. Error entry: `code`, `message`, `data: JSONValue?`.
- [ ] An internal `update(from:)` on each class that takes the engine's entry value and writes only the fields that changed (no write when a value is equal), so that Observation does not invalidate rows that did not change.

The engine (from FoundationModelsACP) owns the merge rules. These classes keep no merge rules of their own.

## Acceptance Criteria
- [ ] Each entry kind of section C of the design has a class with the fields above.
- [ ] `update(from:)` with an equal value causes no observation change.
- [ ] Setting `messageId` and `sendState` on a local user message does not change its `id`.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/TranscriptEntryTests.swift`: a test for each kind that `update(from:)` copies the fields; a `withObservationTracking` test that an equal value does not fire `onChange`; a test that terminal `text` replaces bad UTF-8 bytes; a stable-`id` test for the local user message.
- [ ] `swift test --filter TranscriptEntryTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.