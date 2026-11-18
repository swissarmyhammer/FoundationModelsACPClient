---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qvmt6kqacw0cqve9psxkqk
  text: |-
    The external dependency is satisfied: FoundationModelsACP origin/main cb9aee7 (from foundationmodelsacp-be).
    - Send: `ClientSideConnection.forkSession(_ ForkSessionRequest) -> ForkSessionResponse`.
    - `ForkSessionRequest(cwd:sessionId:additionalDirectories:mcpServers:systemPrompt:meta:)`.
    - The cut: `SAH.ForkCut(messageId:side:)` with side `.before` or `.after`. Write it with `try cut.inject(into: request.meta)`. No cut means the last completed turn.
    - The method name is `forkSession` (as `deleteSession`), not `sessionFork`.
  timestamp: 2026-11-18T17:35:33.587245+00:00
depends_on:
- 01M7QV7G2QQBY03YWR4MWNXM2S
position_column: todo
position_ordinal: '8180'
title: 'ConnectionModel.forkSession(_:cut:): fork a session with session/fork (D205)'
---
## External dependency: do not start before it is on main

FoundationModelsACP must have `ForkSessionRequest`, `ForkSessionResponse` and `SAH.ForkCut` on `main`. The session foundationmodelsacp-be sends the sha. On 2026-11-18 FoundationModelsACP main (7e31ad0) has no fork types. This task also depends on the flags task 01M7QV7G2QQBY03YWR4MWNXM2S.

## Goal

The app forks a session only through this call (D205, TestudoApp/features/decisions.md, commit 483664d). A fork is a new top-level session with a copy of the history of the source up to a cut point.

Brief: /Users/wballard/github/swissarmyhammer/.briefs/fork/acpc-brief.md. Overview: overview.md in the same folder.

## Current state

- `ConnectionModel.newSession(_:)` (`Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift:58`): it checks the additional directories capability, removes the MCP servers that the agent does not advertise, marks the session as opening, makes and registers the `SessionModel`, and handles a close of the connection during the call.
- `ConnectionModel.resumeSession(_:)` (`:184`): it requires `canResumeSessions`, runs one resume of a session at a time (`resumeTurns`), refuses a child session, and replays the history into the model.
- No code sends `session/fork`.

## Change

1. `public func forkSession(_ sessionId: SessionId, cut: SAH.ForkCut? = nil) async throws -> SessionModel` on `ConnectionModel` (the session can change the name).
   - Refuse with `requireCapability(canForkSessions, method: …)` before it sends. Refuse a non-nil `cut` when `canForkWithCut` is `false`. Add the method name to `ClientRequestSpan.Method` like the other methods.
   - Send `ForkSessionRequest` with the `sessionId`, the `cwd` and the additional directories of the source model, and the MCP servers of the source as `session/new` sends them (use the same removal of unadvertised servers). Put the cut in `_meta` with the `SAH.ForkCut` inject helper when it is not `nil`.
   - Make the `SessionModel` of the new session from the response (`configOptions`, `availableCommands`, and the other fields), as `newSession` does, and register it in `openSessions`. Use the same code path as `newSession` for the opening ticket and for a close of the connection during the call. Do not write a copy of that code: extract a shared helper if necessary.
2. The history: the brief says that the new model reads the history of the fork with `session/resume`, as for a resumed session, so the tab shows the copied turns. Decide with the real ACP types: if the agent sends the history in the fork response or as updates, use that; otherwise resume the new session with `resumeSession`. When `canResumeSessions` is `false`, the fork gives a model with no history; write that in the doc comment.
3. Doc comments in STE, in the style of `newSession` and `resumeSession` (each `Throws` case).

## Tests (Swift Testing, with a scripted agent)

- [ ] An agent with `fork: {}`: `forkSession` sends the request with `sessionId` and `cwd` and no cut, and gives a model with the new id in `openSessions`.
- [ ] An agent with the cut flag: the request has `_meta.sah.forkCut` with the message id and the side.
- [ ] An agent with no `fork`: the call throws `unsupported` before it sends.
- [ ] An agent with `fork` and no cut flag: a call with a cut throws before it sends; a call with no cut works.
- [ ] The new model shows the copied turns of the source.
- [ ] A close of the connection during the call: the call throws `ConnectionError.closed`, and no model stays in `openSessions`.

## Acceptance

- [ ] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`, and send the sha to agentviewkit-0b and testudoapp-9a. #d205