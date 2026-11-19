---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7syxhz7293cmgzy9xv4255k
  text: |-
    Research:
    - The engine order (`engine.entries`) and `engineTranscript` (transcript order) are not always the same list. Two differences: (1) a held echo (a user-message echo that arrives while a prompt waits) is in the engine but not in the transcript; (2) a local prompt is in the transcript at its send position, but its echo is in the engine at its arrival position. An entry that arrives between the send and the echo thus has a different order.
    - The agent renders its Markdown from its engine entries in engine order. Thus engine order is the order that makes the text of the client and the text of the agent the same (D202). Plan: the public `wireEntries` gives `engine.entries`, `markdown(options:)` renders `wireEntries`, and `engineTranscript` is removed. One read of the data only. A new test shows the order difference.
    - Turn end: `agentState` is observable and `idle` ends the foreground work of the agent. The doc comment of `wireEntries` names it. No new state.
    - The internal map becomes `transcriptEntriesByWireID`.
  timestamp: 2026-11-19T13:11:14.663464+00:00
- actor: claude-code
  id: 01m7sz3w0a9ta46m66m61ng8xe
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPClient/Model/SessionModel.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Markdown.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelWireEntryTests.swift (new, 6 tests), Tests/FoundationModelsACPClientTests/Model/SessionModelMarkdownTests.swift (1 new test). `timeout 1800 swift build`: exit 0, only the MLX "missing creator for mutated node" warning. `timeout 1800 swift test`: 917 tests in 77 suites passed, exit 0, only the MLX warning.
    - what changed: the internal map is now `transcriptEntriesByWireID`. The public `wireEntries` gives `engine.entries` (engine order). The public `entry(forWireID:)` reads the map. `engineTranscript` is removed, and `markdown(options:)` renders `wireEntries`. Thus one read of the data stays. The doc comment of `wireEntries` names `agentState` (`idle`) as the observable turn end. No new state.
    - behavior change: the Markdown document now uses engine order, not transcript order. The new test `theDocumentKeepsTheEngineOrderWhenAnEchoArrivesAfterAnAgentMessage` failed before the change (the client put the local prompt before an agent message that arrived first; the agent text puts the echo after it). Now the text of the client and of the agent are the same, as D202 requires.
    - next: /review. "Push main, and send the sha" stays open.
  timestamp: 2026-11-19T13:14:41.546848+00:00
- actor: claude-code
  id: 01m7sz5sj2pavpsfq2phnbyshr
  text: |-
    ### test - green
    - evidence: swift test (root) - 917 tests in 77 suites passed, 0 failed, 0 skipped. swift build --build-tests --package-path IntegrationTests - build complete.
    - warnings: only the allowed MLX "missing creator for mutated node" warning for mlx-swift_Cmlx.bundle.
    - next: review or commit.
  timestamp: 2026-11-19T13:15:44.578415+00:00
- actor: claude-code
  id: 01m7sz68s3a9ap3gz96767xw90
  text: |-
    ### commit — changed
    - evidence: 0e822ca feat(model): the session shows the entries of the wire in engine order (local commit, not pushed)
    - next: push later, after the CI run on main ends
  timestamp: 2026-11-19T13:16:00.163005+00:00
position_column: doing
position_ordinal: '8180'
title: 'SessionModel: the entry of a wire id, and a public read of the merged engine entries (D207)'
---
## Goal

Session search (D207 (d), (f), (h), TestudoApp/features/decisions.md, commit ba585e0). "Open at the hit" needs the transcript entry of a wire id. The local index of the app (Q66) needs the merged engine entries of a session model, for the agents whose sessions our server does not record.

Brief: /Users/wballard/github/swissarmyhammer/.briefs/search/acpc-brief.md. Overview: overview.md in the same folder.

Order: start after ^f2kmt6m is done (one task at a time in this tree). No external dependency.

## Current state

- `SessionModel.wireEntries` (`Sources/FoundationModelsACPClient/Model/SessionModel.swift:380`) is an internal map `[SessionEntry.ID: TranscriptEntry]`. The rollback (`:688-740`) saves and restores it, and a reset (`:774`) clears it.
- The merge engine is private (`:369`).
- `engineTranscript` (`:390`, from ^yfj492s) is internal. It gives the engine entries in transcript order for `markdown(options:)`.

## Change

1. Rename the internal map `wireEntries` to a name that tells what it is, for example `transcriptEntriesByWireID`. Keep it internal (brief item 4).
2. `public func entry(forWireID id: FoundationModelsACP.SessionEntry.ID) -> TranscriptEntry?`: the transcript entry of a wire id, or `nil` for an unknown id or an id of an entry that a rollback removed.
3. `public var wireEntries: [FoundationModelsACP.SessionEntry] { get }`: a copy of the entries of the merge engine, in engine order. If `engineTranscript` gives the same list, use one of them only; do not keep two reads of the same data.
4. A turn end: name an EXISTING observable state of `SessionModel` in the doc comment of `wireEntries` that the app can watch to know that a turn ended. Do NOT add a new busy state, turn state or event stream (rule of this repo: observable lists are the API).
5. The app gives these entries to `SessionSearchChunker.chunks(of:)` of FoundationModelsACP. Do not chunk in this package. Do not add a search dependency.
6. Doc comments in STE.

The text form of a wire id is NOT in this task: it belongs in FoundationModelsACP (see ^ the D207 text form task).

## Tests (Swift Testing)

- [x] A model with a user message, an agent message and a tool call: each wire id gives its entry, and an unknown id gives `nil`.
- [x] After a rollback, the id of a removed entry gives `nil`.
- [x] `wireEntries` gives the entries of the engine in order.
- [x] `wireEntries` after a `session/load` (or `session/resume`) replay is the same as for the live model.

## Acceptance

- [x] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`, and send the sha to agentviewkit-0b and testudoapp-9a. #d207