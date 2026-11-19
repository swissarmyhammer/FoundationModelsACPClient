---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7t5sz7nyh0cq233hthntwbx
  text: |-
    agentviewkit-0b accepted this shape. Their requests, now part of this task:
    1. The observed `wireID` must work for EVERY entry kind with one predicate. `SessionModel.transcript` is `[TranscriptEntry]` (the enum). Thus the enum `TranscriptEntry` must also give `public var wireID: SessionEntry.ID?`, which forwards to the object of each case, so that `session.transcript.first { $0.wireID == hitID }` compiles and Observation tracks the read of each object.
    2. The doc comment of `wireID` states that a streamed token does not change it. AgentViewKit reads it across the whole transcript in a view body, so a change on each token costs a full body pass.
    Add a test: the predicate `transcript.first { $0.wireID == id }` finds a tool call, an agent message and a linked local user message.
  timestamp: 2026-11-19T15:11:37.205298+00:00
- actor: claude-code
  id: 01m7t5wpwhtceabh4hgmqa5hbx
  text: |-
    Research done. Findings:
    - Ten entry classes conform to `ObservableTranscriptEntry`. Nine come from the wire (`init(wire:)`). `UserMessageEntry` also has a local init. `ErrorEntry` is always local.
    - `linkPrompt(_:)` is the only place that links a local user message. Two callers reach it: `resolvePrompt` (echo first, then response) and `promptCorrelator.observe` (response first, then echo).
    - `resetTranscript()` (a replay with history) removes all keys of `transcriptEntriesByWireID` and drops the local messages from the transcript. Before this change no field of a local message changed in a replay, so a restore of `wireID` from the map would write the same value. Plan: `resetTranscript()` sets the `wireID` of each linked local message to `nil` (the map no longer links it), and `restore(_:)` writes the `wireID` back from the saved map. Thus `wireID` is non-nil only while the map links the object.
    - The validator dump for `.swift` is 617 KB (60 rules), too large to read whole; I read the rule list and follow the general rules (doc each public item, no copy, small functions).
  timestamp: 2026-11-19T15:13:06.961160+00:00
- actor: claude-code
  id: 01m7t64nd4s5j5xvvzjb23ccmg
  text: |-
    Implementation landed (not committed, not pushed).
    - `ObservableTranscriptEntry` has `var wireID: SessionEntry.ID? { get }`. Each of the ten entry classes stores it as `public internal(set) var wireID`. The nine wire classes set it in `init(wire:)`. A local `UserMessageEntry` and `ErrorEntry` start with `nil`.
    - `TranscriptEntry` forwards `wireID` (`@MainActor`, like `init(wire:)` and `update(from:)`), so `transcript.first { $0.wireID == hitID }` compiles and Observation tracks the read on the object.
    - Writes happen only when the link changes: `linkPrompt(_:)` writes the echo id; `resetTranscript()` writes `nil` on each linked local prompt; `restore(_:)` writes the id back from the restored map. A new private `linkedLocalPrompts` gives the local user messages that the map links. No write on a streamed chunk.
    - Discovery: before this change a replay changed no field of a local message, so a restore alone would write the same value. Thus `resetTranscript()` now clears the link value, and the rollback puts it back. The invariant: a local message has a non-nil `wireID` only while the map links it.
    - The doc of `entry(forWireID:)` tells that Observation does not track the call, and that a view reads the observable `wireID` to see a later link.
    - TDD: each new test failed first (compile, then the link tests, then the reset test, then the rollback test), then passed.
    - Tests (in `SessionModelWireEntryTests.swift`): the wire id of each of the nine wire kinds; nil on a local error; nil on a local prompt before its link; the echo id after the link; the observation fires on a link with the same echo text; a streamed agent chunk fires no observation of any `wireID`; a replay with history removes the link; a failed replay puts it back; the predicate finds a tool call, an agent message and a linked local prompt.
    - `swift build`: exit 0, only the MLX warning. `timeout 1800 swift test`: 928 tests in 77 suites passed, only the MLX warning.
  timestamp: 2026-11-19T15:17:27.588844+00:00
- actor: claude-code
  id: 01m7t64r593cpjk79yq6h0t92v
  text: |-
    ### implement — changed
    - evidence: 13 files — Sources/FoundationModelsACPClient/Model/{TranscriptEntry,UserMessageEntry,AgentMessageEntry,ThoughtEntry,ToolCallEntry,TerminalEntry,PlanTranscriptEntry,UnknownEntry,CompactionEntry,SessionMessageEntry,ErrorEntry,SessionModel}.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelWireEntryTests.swift; `timeout 1800 swift test`: 928 tests in 77 suites passed, the only warning is the MLX warning
    - next: /review. The acceptance item "Push main, and send the sha" stays open.
  timestamp: 2026-11-19T15:17:30.409693+00:00
- actor: claude-code
  id: 01m7t66strfeewgyrkfzek6228
  text: |-
    ### test — green
    - evidence: swift test (root) — 928 tests in 77 suites passed, 0 failed, 0 skipped. swift build --build-tests --package-path IntegrationTests — build complete, exit 0.
    - warnings: only the allowed MLX "missing creator for mutated node" warning for mlx-swift_Cmlx.bundle, in both runs.
    - next: review
  timestamp: 2026-11-19T15:18:37.656219+00:00
- actor: claude-code
  id: 01m7t67b95xvdwa0t1d8dnrcxn
  text: |-
    ### commit — changed
    - evidence: local commit feat(model): each transcript entry shows an observed wireID (not pushed)
    - next: push after CI check
  timestamp: 2026-11-19T15:18:55.525824+00:00
position_column: doing
position_ordinal: '8180'
title: Each transcript entry shows its wire id as observable state (D207, for AgentViewKit)
---
## Goal

AgentViewKit (task 01M7T4V7XC0JEJC4FRA9XVJ5V8, D207 (f)) finds a search hit with `SessionModel.entry(forWireID:)`. One case does not work: a hit can come before the echo of its prompt. When the echo links to the local user message, `entry(forWireID:)` changes from `nil` to that message, but no observed value changes. Thus the thread does not reveal or mark the hit.

## Current state

- `transcriptEntriesByWireID` (`Sources/FoundationModelsACPClient/Model/SessionModel.swift`) is `@ObservationIgnored`.
- `linkPrompt(_:)` (`SessionModel.swift:1073`) writes the link (`:1081`). When the echo has the same text, `update(from:)` writes no field, so no observed value of the user message changes. An AVK probe with `withObservationTracking` saw no change on `transcript`, `agentState`, or on `messageId`, `sendState`, `content` and `meta` of each user message.

## Decision: state on the entry, not a revision counter

AgentViewKit proposed `public private(set) var wireLinkRevision: Int`. Do NOT add it. It is an event counter, and this repo does not add event signals to the models: a change shows as observable state, and observable `Identifiable` lists are the API.

## Change

1. Add `var wireID: FoundationModelsACP.SessionEntry.ID? { get }` to `ObservableTranscriptEntry` (`Sources/FoundationModelsACPClient/Model/TranscriptEntry.swift:155`). Each entry class stores it as an observed property with `internal(set)`.
   - An entry from the wire has its engine id from its start.
   - A local user message has `nil` until `linkPrompt(_:)` links it. Then it has the engine id of the echo.
   - A rollback sets each value back to its value before the replay. Save and restore it with the map.
   - A local error entry has `nil`.
2. `entry(forWireID:)` stays as it is. Its doc comment tells that a view watches the `wireID` of the entries (for example `transcript.first { $0.wireID == hitID }`) to see a link that comes later.
3. The value does not change on a streamed token: write it only when the link changes.
4. Doc comments in STE.

## Tests (Swift Testing)

- [x] A wire entry has its engine id as `wireID`.
- [x] A local user message has `nil`, and after its echo links it has the id of the echo. `withObservationTracking` on its `wireID` sees the change also when the echo text is the same as the local text.
- [x] A streamed agent chunk does not change any `wireID`, and an observation of it does not fire.
- [x] A failed replay sets the `wireID` of a linked local message back.

## Acceptance

- [x] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`, and send the sha to agentviewkit-0b. #d207