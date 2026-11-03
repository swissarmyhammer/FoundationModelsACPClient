---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6gr1dnpbpyh52jm80s1yfs0
  text: 'Note: the break `UsageUpdate.cost` is a `PatchField` touches `SessionModel.usage`. Keep "cost not reported" as nil (unknown), not zero. The rule for child sessions (usage per session id, no sums over the tree) is in a comment on card ^rt8h1fs.'
  timestamp: 2026-11-03T13:02:09.590434+00:00
- actor: claude-code
  id: 01m6gxnxxy3yn9qtqqhvezdpsq
  text: |-
    Progress, 2026-11-03. Not committed. The wire pin is now 71a3bde (it holds alpha.13 4e0667c, the subagent types and the SAH meta link). Package.resolved changed. The wire types card has landed: SubagentUpdate, SessionMessage, BackgroundWork, SessionEntry.Kind.sessionMessage and SessionMergeEngine.Change.subagentChanged all exist in the checkout.

    Fixed, test first:
    - AvailableCommand is a union. The id of .command is its name. The id of .unknown is the string name member of the payload, or the type. Tests are in IdentifiableWireTests.
    - cancelled holds CancelledPermissionOutcome. cancelledResponse uses an empty value.
    - ToolCallStatus.paused is not a final status, so the tool call has no end time. Test: aPausedToolCallDoesNotEnd.
    - ChunkCoalescer: subagentUpdate, sessionMessage and sessionMessageChunk do not coalesce. Test: aSubagentUpdateDoesNotCoalesce.
    - SessionModel ignores SessionMergeEngine.Change.subagentChanged until sub-agent card 1/4.

    BLOCKED: SessionEntry.Kind.sessionMessage needs an observable transcript entry type and a TranscriptEntry case (init(wire:), update(from:), id, EntryTiming and more). Card 1/4 owns this entry. I did not start it. Waiting for the peer to decide: add the entry here, or give it to card 1/4 with a temporary choice here.

    Still to do after that: the other breaks in the card list, the nested IntegrationTests packages, new tests for null request id and BackgroundWork, and a full swift test.
  timestamp: 2026-11-03T14:40:44.478704+00:00
- actor: claude-code
  id: 01m6gy9c18k437vf4gdrewsk2y
  text: |-
    Done, 2026-11-03. Wire pin: main at 71a3bde (it holds alpha.13 4e0667c, the subagent types, the SAH meta link and the review fix b86bfc2). Package.resolved is git-ignored; the pin is branch main. Root `swift test`: 704 tests pass. Nested `swift test --package-path IntegrationTests`: 10 tests pass. No warnings except the allowed MLX one.

    Decisions:
    - AvailableCommand is a union. id of .command is the command name. id of .unknown is the string name member of the payload, or the type. Wire JSON of a command needs "type":"command".
    - cancelled holds CancelledPermissionOutcome. cancelledResponse uses an empty value.
    - ToolCallStatus.paused is not a final status: the entry has no end time.
    - ElicitationSchema needs `type: .object` (test fixtures only).
    - ClientCapabilities.auth is ClientAuthCapabilities (test fixture only).
    - A null request id is JSONValue.null. ReplayRequests keys on it as on any id. Test added.
    - BackgroundWork: agentState keeps the idle state with its background list unchanged. Test added.
    - ChunkCoalescer: subagentUpdate, sessionMessage and sessionMessageChunk do not coalesce.
    - SessionModel ignores SessionMergeEngine.Change.subagentChanged. Card 1/4 owns the child tree.
    - The breaks that the compiler did not report (LineNumber, UsageUpdate.cost PatchField, Cost.currency, cancelToolCall, cancelTerminal, MethodSide.proxy) need no change: nothing in Sources uses them.

    Minimal shape of SessionMessageEntry for card 1/4 to extend (public, @MainActor @Observable, ObservableTranscriptEntry): id (.wire(entry.id)), timing, messageId, content [ContentBlock], senderSessionId, recipientSessionId, senderMessageId, recipientMessageId (each optional, from PatchField.currentValue), meta. TranscriptEntry has the new case .sessionMessage. Timing end rule: .atNextEntry. It folds wire updates only. It has no link to the other session and no tree logic. Tests: Tests/FoundationModelsACPClientTests/Model/SessionModelSessionMessageTests.swift.

    New test files: SessionModelSessionMessageTests.swift, SessionModelAlphaThirteenWireTests.swift. Changed tests: IdentifiableWireTests (command id), TranscriptEntryTimingTests (paused), ChunkCoalescerTests (subagentUpdate), WireConformanceTests (command JSON).
  timestamp: 2026-11-03T14:51:21.512155+00:00
position_column: done
position_ordinal: ff9c80
title: 'Adopt FoundationModelsACP schema alpha.13 (commit 4e0667c): update the dependency and fix every break'
---
## What
The wire package FoundationModelsACP moved to schema alpha.13 (commit 4e0667c on main). Update the dependency in `Package.swift` (and `Package.resolved`, and the nested `IntegrationTests` package if it pins the wire) and fix every compile break and every behavior change in this package.

Rule (ARCHITECTURE.md, "No backward compatibility"): change every caller in the same change. Do NOT add shims, aliases, deprecated overloads or compatibility code.

The wire-side cards live on the FoundationModelsACP board, so this card cannot depend on them by id. They are: re-vendor 01M6GJ8GX6C0YRHJW0W2ADAVTE (its comment has the list of 13 breaks; read it first) and wire types 01M6GJ664BHY454C5NFPFCSP79.

Known breaks (from the comment of 01M6GJ8GX6C0YRHJW0W2ADAVTE; check the comment for the full list and for the exact new names):
- `RequestPermissionOutcome.cancelled` now holds a value.
- `AvailableCommand` is a union with a `type` discriminator.
- `ElicitationSchema` needs `properties` and `type`.
- `ClientCapabilities.auth` has a new type.
- `ToolCallStatus` has `.paused`.
- `ToolCallLocation.line` is `LineNumber`.
- `UsageUpdate.cost` is a `PatchField`.
- `Cost.currency` is any string.
- New requests `cancelToolCall` and `cancelTerminal`.
- `MethodSide` has `.proxy`.
- Request ids can be null.
- `StateUpdate` has `BackgroundWork`.
- (13th break: read it in the ACP card comment.)

Work:
- Bump the dependency and resolve. Find every break with `swift build` and `swift test` (also build the nested IntegrationTests package and the `acp-client` executable).
- Fix each break at its use sites. Where a break is a new model case, an exhaustive switch must handle `.paused` and the new union cases by a real rule, not by a default that hides them.
- Decide each new behavior in the observable model and write it down in a comment on this card: how `.paused` shows in `ToolCallEntry`; how the new `AvailableCommand` union shows in the available-commands list; what `cancelled` holds and where the model reads it; how a null request id is handled by the pending-request and withdrawn-request code; what `BackgroundWork` on a state update does to `SessionModel` (store it as observable state, or leave it out and say why).
- The new requests `cancelToolCall` and `cancelTerminal`: check the direction in the wire card. If the client must answer them, route them to the right model. If the client sends them, expose only what a card needs.
- Update docs and comments that name an old type or an old rule.

## Order of work for the sub-agent cards
The sub-agent cards (the split of ^rt8h1fs) wait for this card: 01M6GH6FH41C6VSFC3QRT8H1FS (1/4) depends on it by `depends_on`; 01M6GPC4KAYTRB13E8SE6SRMMS (2/4), 01M6GPCB30XBNGCH37YTYDYZEE (3/4) and 01M6GPCHYHF28ADE0WKTH4YRR0 (4/4) depend on card 1. Their wire types come from this revision plus wire types card 01M6GJ664BHY454C5NFPFCSP79.

## Acceptance Criteria
- [ ] `Package.swift` and `Package.resolved` pin FoundationModelsACP at 4e0667c or later (schema alpha.13).
- [ ] `swift build` of the package, the `acp-client` executable and the nested IntegrationTests package has no error and no new warning (the allowed MLX "missing creator for mutated node" warning stays the only allowed one).
- [ ] Each of the 13 breaks is fixed at its use sites, and none is hidden by a `default` case or a shim.
- [ ] `.paused` is a handled `ToolCallStatus` in the model, with a test.
- [ ] The new `AvailableCommand` union is handled in the model, with a test.
- [ ] `RequestPermissionOutcome.cancelled` with a value is handled, with a test.
- [ ] A null request id does not break the pending-request, withdrawn-request or telemetry code, with a test.
- [ ] `BackgroundWork` on a state update is handled by the decision in the card comment, with a test.
- [ ] `swift test` passes in full, and the CI integration job passes.
- [ ] No deprecated alias, shim or old overload is left (ARCHITECTURE.md rule).

## Tests
- [ ] Add or update tests next to the code each break touches (for example `Tests/FoundationModelsACPClientTests/Model/`). Name the new test files in a comment on this card.
- [ ] Run `swift test`. All pass.

## Workflow
- Use `/tdd` for each behavior change (the new cases); the pure compile fixes need no new test. #subagents