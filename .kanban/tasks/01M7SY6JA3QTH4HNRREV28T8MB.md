---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
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

- [ ] A model with a user message, an agent message and a tool call: each wire id gives its entry, and an unknown id gives `nil`.
- [ ] After a rollback, the id of a removed entry gives `nil`.
- [ ] `wireEntries` gives the entries of the engine in order.
- [ ] `wireEntries` after a `session/load` (or `session/resume`) replay is the same as for the live model.

## Acceptance

- [ ] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`, and send the sha to agentviewkit-0b and testudoapp-9a. #d207