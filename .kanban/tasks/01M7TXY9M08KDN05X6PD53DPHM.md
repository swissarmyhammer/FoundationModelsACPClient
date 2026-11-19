---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7ty343xntn7ft2e61hcsaqf
  text: 'From foundationmodelsacp-be (FoundationModelsACP fb08304): for the read-only model, apply `snapshot.updates` to a merge engine (`SessionMergeEngine(replaying: snapshot.updates)`, or the normal `apply(_:)` path of the model). The title is `snapshot.options.title`: no session_info update is in the snapshot, so the read-only model sets its title from the options. A snapshot from a newer format throws `SessionSnapshot.DecodingError.newerFormat(version:)` at decode time; that is the app''s case, not this model''s.'
  timestamp: 2026-11-19T22:16:02.941283+00:00
depends_on:
- 01M7TXXY981MZ52MSTBDJ6NDT9
position_column: todo
position_ordinal: '8380'
title: A read-only SessionModel from a share snapshot, with replace(with:) (D208)
---
## External dependency: do not start before it is on main

FoundationModelsACP must have `SessionSnapshot` on `main` (foundationmodelsacp-be sends the sha). This task also depends on 01M7TXXY981MZ52MSTBDJ6NDT9.

## Goal

A recipient of a shared session sees a read-only tab with no composer (D208 (g), (i), TestudoApp/features/decisions.md, commit d803f1a). AgentViewKit shows the chat of a `SessionModel` that has no connection and refuses each request.

Brief: /Users/wballard/github/swissarmyhammer/.briefs/share/acpc-brief.md (items 2 and 3).

## Current state

- `SessionModel.apply(_:)` folds one `SessionUpdate` (`Sources/FoundationModelsACPClient/Model/SessionModel.swift`).
- A `SessionModel` is made by the `ConnectionModel` for `session/new`, `session/resume` and `session/fork`, with a connection.

## Change

1. A read-only model from a snapshot: `SessionModel(snapshot:)` (or a factory; the session can choose). It applies the updates of the snapshot in order, with no connection. It is not in any `openSessions`.
2. `public let isReadOnly: Bool` (or a computed property): `true` for this model, `false` for each model of a connection. It is a property of the kind of model that never changes for the life of the model. Do NOT add a busy state, turn state or event (rule of this repo).
3. Each request on a read-only model (prompt, cancel, fork, rewind or replay, set mode, set config option, and each other method that sends to the agent) throws a new error `readOnly` before it sends anything. Find each such method; do not miss one. Prefer one guard that all of them use.
4. `public func replace(with snapshot: SessionSnapshot)` on a read-only model: the app calls it when Update Share gives a newer snapshot. Entries that stay the same keep their object identity and their `id` (so the view keeps its scroll position). New entries are added at the end. Changed entries update in place. If the newer snapshot does not start with the same entries, the model may rebuild; document what happens. On a model that is not read-only, `replace(with:)` throws `readOnly`'s opposite case or a precondition error: choose and document.
5. Doc comments in STE.

## Tests (Swift Testing)

- [ ] A model from a snapshot shows the same transcript (ids and texts) as a live model that got the same updates.
- [ ] `isReadOnly` is `true` for it, `false` for a model of a connection.
- [ ] A prompt, a cancel, a fork and a set mode on a read-only model each throw `readOnly`, and nothing is sent.
- [ ] `replace(with:)` with a snapshot that has two more turns adds them, and the old entries keep their object identity.

## Acceptance

- [ ] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`, and send the sha to agentviewkit-0b and testudoapp-9a. #d208