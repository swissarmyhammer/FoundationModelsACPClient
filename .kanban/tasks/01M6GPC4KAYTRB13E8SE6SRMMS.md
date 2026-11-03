---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6gzq1qfks017fperdvd98we
  text: |-
    Ready for review, 2026-11-03. Not committed: changes are in the working tree. Root `swift test`: 746 tests pass (17 new in SubagentResumeTests). Review (review working): clean after 3 fix rounds.

    Implemented:
    - Replay: a child made during a replay with history copies the replay phase of its parent, is unconfirmed, and ends its replay when the root endReplay runs (endChildReplays, recursive). A failed replay or a subscription end ends each child replay too. A snapshot of a replay writes only title, description, cwd, additionalDirectories and startedByToolCallId. It never writes capabilities or state, and never confirms.
    - Confirmation: SessionModel.isWorkStateConfirmed. A child is unconfirmed after a resume (workState unknown, capabilities nil, cancel refused) until its first current snapshot. A live child state_update does not confirm. A live first announcement confirms.
    - Resume: replayFrom set closes and removes every child model before the replay (rebuilt from the replayed announcements). replayFrom nil keeps them and invalidates their state.
    - Removal: SessionModel.startedByToolCallId (from _meta.sah.agentRun.toolCallId); ToolCallEntry.childSession (from _meta.sah.agentRun.sessionId, weak). A child is removed (isClosed true, out of children, stream stopped) when its linked tool call reaches completed, failed or cancelled. A child with no link stays. Both announcement branches refresh the links.
    - Test support: ConnectedStub.make, BaselineStubAgent, UpdateSendingStubAgent, childModel/waitForChild shared by SubagentTreeTests and SubagentResumeTests.

    Known limit for card 4: the engine of the parent folds a snapshot onto the earlier one. A current snapshot that omits `state` still folds the history state, so the model then shows the history state as confirmed. Fixing it needs the raw current patch (wire change) or the part 4 rule for a missing snapshot. Not done here: needsAttention and notification rules (cards 3 and 4), descendants (card 3).
  timestamp: 2026-11-03T15:16:18.287725+00:00
depends_on:
- 01M6GH6FH41C6VSFC3QRT8H1FS
position_column: doing
position_ordinal: '80'
title: 'Sub-agent sessions 2/4: resume replay, confirmation, rebuild and removal'
---
## What
Part 2 of 4 of the split of card ^rt8h1fs. Part 1 (tree and routing) comes first. This card adds the replay and resume rules for child sessions.

WAITS FOR the wire cards on the FoundationModelsACP board (other board, so not in depends_on): re-vendor 01M6GJ8GX6C0YRHJW0W2ADAVTE, wire types 01M6GJ664BHY454C5NFPFCSP79, SAH meta 01M6GP1QC785QS2BS3TNVMKT7A (the `_meta.sah.agentRun` link is needed for the removal rule).

ACP rules (RFD "Subagent Sessions", replay and resume). Newest user decision wins:
- All history of the tree is sent BEFORE the resume response. The response ends the replay of child models. There is no per-child end marker.
- Snapshots that arrive before the response are history. They must not authorize mutations and must not confirm current activity. Current snapshots come AFTER the response.
- Replay must not reissue permission, elicitation or other agent-to-client requests.

Client work:
- A child model made during a replay starts in `.replaying`. It ends its replay at the response of the root request. See "Replay bookkeeping" below.
- Everything in the replay phase is history: no notification, sound, attention mark or auto action.
- On resume, invalidate cached child work state and capabilities.
- After the response, a child is UNCONFIRMED: it shows `workState` unknown, its effective capabilities are empty, and cancel stays disabled until its first current snapshot and until the resume has succeeded. Add observable `SessionModel.isWorkStateConfirmed`.
- Same-connection resume of a session that is open in the client and live in the agent is supported. Before the replay starts, drop the child models of the session: mark them closed (`isClosed` true), remove them from `children`, `descendants` and any view lookup. Rebuild them only from the replayed `subagent_update` messages. A resume without `replayFrom` keeps the child models.
- Add observable `SessionModel.isClosed`. It becomes true when the child is removed or the session closed. A closed session is not in `children` or `descendants`. The model keeps the closed object only while a view holds it.
- Removal by tool call: a finished child is removed when its linked tool call reaches a final status (completed, failed, cancelled). The link is `_meta.sah.agentRun`: `{ toolCallId }` on the `subagent_update`, `{ sessionId }` on the `tool_call` and `tool_call_update` of the `agents` call. Add `SessionModel.startedByToolCallId` and `ToolCallEntry.childSession`. A child with no link is not removed, and stays until its parent closes. No child traffic is applied after the removal.
- A missing snapshot: if the response arrives while a child is still `.replaying` and no current snapshot follows, do not wait for ever. See part 4 for the failure mark.

## Replay bookkeeping (code fact, `SessionModel+Stream.swift`)
`ReplayRequests` and `replayPhase` are per `SessionModel`. Only the root model gets `beginReplay`. It ends when the stream of that model yields `.requestFinished` for a `session/resume` request whose start `ConnectionModel+Sessions.swift` (`watchResumeStarts`) recorded. A child model has no `beginReplay`, no `ReplayRequests` and no marker. So: when the root `endReplay(succeeded:)` runs, it must also end the replay of every child model that is `.replaying` (walk `children`). The root `endRunningReplayAsFailure()` must do the same. Do not give a child its own `ReplayRequests`.

## Acceptance Criteria
- [ ] No child current snapshot is applied as current before the response in a replay.
- [ ] A child made during a replay is `.replaying`, and ends its replay at the response of the root request.
- [ ] A live `state_update` after the response is never an end signal of a replay.
- [ ] After the response, a child is unconfirmed (`isWorkStateConfirmed` false, `workState` unknown, capabilities empty, cancel refused locally) until its first current snapshot.
- [ ] Every child gets a current snapshot after the response; after it, `isWorkStateConfirmed` is true and capabilities are the new ones.
- [ ] A replay with no `replayFrom` still announces the children and sends current snapshots, and keeps the child models.
- [ ] Replayed content raises no `needsAttention`, no notification, no sound and no auto action.
- [ ] Same-connection resume with replay: the client has the same tree as the agent, built only from the new announcements; old child models are closed (`isClosed`); a child gone in the agent is not in the tree; capabilities are the new ones; a running child stays running.
- [ ] A child is removed (`isClosed` true) when its linked tool call reaches a final status; a child with no link is kept; no child traffic is applied after removal.
- [ ] `isClosed` turns true on removal, and a view that observes it is told (observation test).
- [ ] Failure of the root replay or end of the subscription ends the replay of each child too.

## Tests
- [ ] `Tests/FoundationModelsACPClientTests/SubagentResumeTests.swift`: all items above. Use the in-process agent (`InProcessAgent.swift`) or a scripted connection.
- [ ] Run `swift test --filter SubagentResumeTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first. #subagents