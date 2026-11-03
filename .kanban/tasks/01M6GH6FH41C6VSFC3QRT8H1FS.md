---
comments:
- actor: wballard
  id: 01m6ghrgm7y94d0gebdf82bmt1
  text: |-
    ADDED REQUIREMENTS from the AgentViewKit design (a floating breadcrumb bar with a dropdown at each crumb, to move between a session and its sub-sessions):
    1. `SessionModel.ancestors`: the chain from the root, root first. Each element is one crumb.
    2. `SessionModel.siblings` (or `parent.children`): the choices of the dropdown of one crumb, in announce order. The root level lists the root sessions of the connection.
    3. Each choice shows `title`, `workState`, and the count of pending requests.
    4. `SessionModel.needsAttention`: true when this session or any descendant is `requires_action` or has a pending request. It is computed, so every view gets the same answer, and a deep question shows on the ancestors.
    5. Removal: when a child goes away (the parent closed or a replay rebuilt the tree), the model says the session is gone. A view must be able to fall back to the parent. Do not keep a stale object that looks live.
    6. Which session a window shows is VIEW state in AgentViewKit, not model state. Do not put a "selected session" in ConnectionModel.
    Acceptance criteria to add: ancestors order for a depth 3 tree; siblings order; needsAttention rises from a grandchild and falls when its request is answered; a removed child is reported as gone. Tests in SubagentSessionModelTests.
  timestamp: 2026-11-03T11:12:26.247338+00:00
- actor: wballard
  id: 01m6gj0msm0zm1khq8r23ddpr1
  text: |-
    ADDED REQUIREMENT (jump command in AgentViewKit, EditorKit commands):
    7. `SessionModel.descendants`: a flat list of all sub-sessions below this session, depth first, in announce order. Each entry gives the session, its `title`, and its path from the root (the titles of its ancestors). AgentViewKit uses it for a quick-open "jump to a sub-session by name", which shows paths such as "Agent > Reviewer > Linter". It is computed from `children`, so it keeps no copy and it is always in step with the tree.
    Acceptance criteria to add: `descendants` order for a depth 3 tree with two children at each level; a child added or removed changes `descendants`; each entry path equals the `ancestors` titles of that session. Tests in SubagentSessionModelTests.
  timestamp: 2026-11-03T11:16:52.660960+00:00
- actor: wballard
  id: 01m6gj8r0sh5w6eaffjxfrf2nx
  text: |-
    ADDED REQUIREMENTS (working model: ACP messages become an easy-to-consume @Observable SwiftUI model; the views read ready-to-show values and build nothing):
    8. `SessionPathEntry`: a small value type that the model gives for each crumb choice and each jump entry. Fields: the session id, `title`, `path` (the titles from the root, as an array), `workState`, `pendingRequestCount`, `needsAttention`. `SessionModel.ancestors`, `siblings` and `descendants` give these entries (or a view of them), so the breadcrumb dropdown and the jump list do not build them. It is Hashable and Sendable, and cheap to compare.
    9. `SessionModel.isClosed`: an observable flag. It becomes true when the child is removed (the parent closed, or a replay rebuilt the tree) or the session closed. A view that shows a closed session reads the flag and falls back to the parent. The model keeps the closed object only as long as a view holds it; it does not list it in `children` or `descendants`.
    Acceptance criteria to add: an entry for each of ancestors, siblings and descendants carries the right path and state; `isClosed` turns true when a child is removed and a view that observes it is told (observation test); a closed session is not in `children` or `descendants`. Tests in SubagentSessionModelTests.
  timestamp: 2026-11-03T11:21:18.105083+00:00
- actor: wballard
  id: 01m6gkkft0asftytpkrfvsnj2z
  text: |-
    DECISION (user, 2026-11-03): a child session knows its parent, and its replay ends with its OWN history, not with the response of the root. The end signal is the child state_update snapshot.
    AGENT RULE: in a replay, the agent sends the `state_update` snapshot of each child as the LAST message of that child replay. A child with no history still sends it. The agent sends the snapshots of ALL children before it sends the resume response, so no child waits for a marker that never comes.
    CLIENT RULE: a child model made during a replay starts in `.replaying`. It ends its replay on the first `state_update` for that child that arrives inside the replay (before the response). A `state_update` after the response is live and never an end signal. If the response arrives while a child is still `.replaying` (the agent sent no snapshot), end that replay as a failure and mark the child `unknown`; do not wait for ever.
    Acceptance criteria to add: the last replayed message of each child is its state_update; a child with no history sends one; all snapshots precede the response; a child made mid-replay ends on its snapshot; a live state_update after the response does not end any replay; a missing snapshot ends the child replay as a failure at the response.
  timestamp: 2026-11-03T11:44:38.720652+00:00
- actor: wballard
  id: 01m6gkn65fmewex2bs9914ny5p
  text: |-
    DECISION (user, 2026-11-03), gap 3: a resume on the SAME connection, of a session that is open in the client and live in the agent, is a supported case. RFD rule: before a resume succeeds the client invalidates cached child state and capabilities; historical capability grants never carry over.
    CLIENT: `resumeInTurn` already replays into an open model. For a tree it must, before the replay starts, drop the child models of the session (mark them closed, remove them from `children`, `descendants` and any view lookup) and rebuild them from the replayed `subagent_update` messages. Capabilities of a child come only from the new announcements. A view that holds a dropped child sees `isClosed` and falls back to the parent. A replay without `replayFrom` (no replay) keeps the child models.
    AGENT (hot resume): a resume from the connection that already owns the session is allowed; the owner does not change, but the replay of the whole tree is sent again, parent first, each child ending with its `state_update` snapshot. The work continues.
    Acceptance criteria to add: after a same-connection resume with replay, the client has the same tree as the agent, built only from the new announcements; old child models are closed; a removed child (gone in the agent) is not in the tree; capabilities are the new ones; a running child stays running; the old connection rule is not triggered (same owner).
  timestamp: 2026-11-03T11:45:34.383200+00:00
- actor: wballard
  id: 01m6gkq7tfavh740gm4azmy8zj
  text: |-
    DECISION (user, 2026-11-03), gap 4: a child session that fails to restore is announced, not hidden. The agent sends `subagent_update` for it with `state: unknown` and a short reason in `_meta` (for example missing tool, model mismatch, record unreadable). The RFD meaning of `unknown` is lost observability while ACP stays connected; it is nonterminal and the client must not show stale activity as live. The root still resumes.
    THIS REPLACES the earlier text of the cold resume task that says a failed child is kept out of the tree and is not in `children`: a failed child IS in the tree, as unknown.
    AGENT: a failed child has no live Router session, so there is no projector, no history, and no `capabilities` (no cancel). Announce it with its stable id, its parent (from `agentSpawn.parentSessionId`, which is known, so no guess), its title, `state: unknown`, `capabilities: null`, and the reason in `_meta`. Its own replay ends with that announcement (no history to send). Its descendants cannot be restored either: announce them as unknown too, or not at all; decide and write it in a task comment.
    CLIENT: the child model has `workState` unknown and an observable `restoreFailure` (a short reason string, nil when fine). A view shows it as lost, with the reason, and offers no prompt or cancel. It counts in `children`, `descendants` and `ancestors`. `needsAttention` is false for it unless the user must act (decide in the client card).
    Acceptance criteria to add: a recorded child with a missing tool resumes the root, and the client sees the child as unknown with the reason; no cancel capability; the child keeps the same id on a second resume; descendants of a failed child follow the written rule.
  timestamp: 2026-11-03T11:46:41.615748+00:00
- actor: wballard
  id: 01m6gkytkybtjd98n4z660rpk0
  text: |-
    DECISION (user, 2026-11-03), SUPERSEDES the earlier comment "a child session knows its parent, and its replay ends with its OWN history" (the per-child end on a state_update snapshot before the response). That text misread the subagents RFD. FOLLOW ACP (RFD "Subagent Sessions", section replay and resume):
    - All history of the tree (associations and child history) is sent BEFORE the resume response ("All history selected for this replay MUST be sent before the response"). The response completes the best-effort child replay. A child replay ends at the response. There is no per-child end marker in ACP.
    - When replay is requested, the successful response is the freshness boundary for child work state and mutation-capability snapshots. Snapshots sent before the response are historical: they MUST NOT authorize client mutations and MUST NOT confirm current activity. Current snapshots are sent AFTER the response. Without a replay, announcements and snapshots may come before or after the response.
    - The ancestor chain is announced parent before child, before any use of a child in live traffic. Replay MUST NOT reissue permission, elicitation or other agent-to-client requests.
    AGENT: replay (associations, child history, no child state_update as a current fact) -> parent current state_update snapshot (with the `background` list) and session info -> response -> current `subagent_update` snapshots of every child (state and capabilities) -> only then any re-drive (a snapshot must precede a running update of the same child so a delayed copy cannot overwrite a newer state). A cold-restored child snapshot is `idle`. Do not echo a synthetic user_message for a re-drive mail (agent-started foreground work needs none).
    CLIENT: on resume the client invalidates cached child work state and capabilities. Child models made during the replay are `.replaying` and end their replay at the RESPONSE of the root request. After the response a child is UNCONFIRMED (shown as unknown, effective capabilities empty) until its first current snapshot; child controls (cancel) stay disabled until then, and until the resume has succeeded. Everything inside the replay phase is history: no notification, sound, attention mark or auto action. Add `SessionModel.isWorkStateConfirmed` (or an equivalent) as an observable.
    Acceptance criteria to add: no child current snapshot before the response in a replay; every child gets a snapshot after the response; a child is unconfirmed and not cancellable between the response and its snapshot; the re-drive start follows the snapshots; a replay with no replayFrom still announces the children and sends current snapshots; no needsAttention or notification is raised by replayed content.
  timestamp: 2026-11-03T11:50:50.238834+00:00
- actor: wballard
  id: 01m6gp1xy2fw1s2x9qea7sqc09
  text: |-
    DECISION (user, 2026-11-03): the agent is a session AND a tool, so it has the behaviors of both. ACP does not link the tool call to the child session, so we add a link in `_meta`, using the SAH extension pattern of the wire package (FoundationModelsACP `SAH/SAHMeta.swift`: payload types under `_meta.sah`). Card for the payload type: see the FoundationModelsACP board, "SAH meta payload that links an agent tool call and its child session".
    THE LINK:
    - On the `subagent_update` of a child: `_meta.sah.agentRun = { toolCallId }`, the id of the `agents` tool call that started the child (the SDK tool call id; the Router record has it as `agentSpawn.parentToolCallId`).
    - On the `tool_call` / `tool_call_update` of that `agents` call: `_meta.sah.agentRun = { sessionId }`, the child session id.
    THE REMOVAL RULE: a finished child is removed. ACP has no removal message. The agent sends none. The CLIENT removes a child from the tree when its linked tool call reaches a final status (completed, failed or cancelled). The agent must therefore send the final `tool_call_update` AFTER the last update of the child and after its final `state_update` (idle), so the client never drops a child that still has traffic coming.
    AGENT: put the link on both messages; keep the order above; the link is also sent in the replay and in the post-response snapshots of a restored child. A child that has no known tool call (a host-started run) carries no link, and stays until its parent closes.
    CLIENT: read the link; `SessionModel` gets `startedByToolCallId` and a tool call entry gets `childSession`; remove the child (set `isClosed`) when the linked tool call is final; keep the child if the link is missing.
    VIEWS: the `agents` tool row in the parent thread is a link that jumps to the child session while it exists; after removal the row stays as history and shows the result.
    Acceptance criteria to add: the link is on both messages; the child is removed on the final tool call status; no child traffic after its removal; a child without a link is not removed; replay and snapshots carry the link; cancel through `tool_call/cancel` and through `session/cancel` on the child id reach the same run.
  timestamp: 2026-11-03T12:27:29.090175+00:00
- actor: claude-code
  id: 01m6gr1ccz6j39s7558r015r4s
  text: |-
    ADDED RULE (ACP Subagent Sessions RFD; relayed by the agent-side session): `SessionModel.usage` exists today. For child sessions: show usage per session, under its own session id. Never add or subtract the usage or cost of a parent and its children. Show a child cost as unknown (nil), not zero. The work to send usage for children belongs to a card on the FoundationModelsACPAgent board; the client only follows this rule.
    Acceptance criteria to add: a `usageUpdate` with a child id changes only the child `usage`; the parent `usage` is unchanged; no value is a sum over the tree; a child with no reported cost shows nil cost, not zero. Tests in SubagentTreeTests.
  timestamp: 2026-11-03T13:02:08.287350+00:00
- actor: claude-code
  id: 01m6gymzpsvnbk28y4zt9n1gnf
  text: |-
    Ready for review, 2026-11-03. Not committed: the changes are in the working tree. Root `swift test`: 729 tests pass, with 25 new tests in SubagentTreeTests. No new warnings.

    What changed (public API):
    - SessionModel: parent (weak), children (announce order), title, description, capabilities, workState (SessionWorkState: running, requiresAction, idle(stopReason, error), unknown). workState is derived from agentState. SubagentSessionError.notPermitted(operation:).
    - A child is a SessionModel like any root, at every level. No code path depends on depth.
    - ConnectionModel makes the child on the first folded subagent_update, subscribes it, and sets the parent before any event of its id. Later announcements change the same object. The engine of the parent folds the patch rules. A mirrored `state` is written only when the parent changed it, so it never overwrites a later state_update of the child.
    - Requests with a child id (permission, elicitation) go to the child through childSession(for:), a tree walk under the open sessions. An update of an unannounced id changes no model.
    - session/list never adds a child to sessions.
    - cancel() on a child sends session/cancel with the child id when capabilities.cancel is set; otherwise it throws. prompt, setConfigOption, close, resume and delete throw SubagentSessionError.notPermitted without sending. A child offers no slash commands.
    - markClosed on a parent closes and removes its children at every level.

    Notes for cards 2 to 4:
    - Not done here, as the card says: replay and resume of children, isWorkStateConfirmed, isClosed rule by tool call, ancestors, siblings, descendants, needsAttention, restoreFailure.
    - DECISION to confirm: cancel on a child with no capabilities.cancel throws (reads "allows only what the child capabilities advertise"). If the coordinator wants cancel always allowed, change one closure in SessionModel+Prompt.swift.
    - Resume of a root session that is not open still creates the model before the request. Children of a resumed root are made again by the replayed subagent_update (card 2 owns the replay rules).
    - New files: SessionModel+Subagent.swift, ConnectionModel+Subagents.swift, Tests/.../SubagentTreeTests.swift. MailOrderStubAgent got send(_:to:).
  timestamp: 2026-11-03T14:57:42.105822+00:00
- actor: claude-code
  id: 01m6gyr7hdv47n1813ebcbdp9x
  text: |-
    ### review — clean
    - evidence: review working, 10 files, 0 findings (1 refuted).
    - next: commit and push to main; coordinator keeps the throw for cancel() on a child with no capabilities.cancel.
  timestamp: 2026-11-03T14:59:28.429712+00:00
depends_on:
- 01M6GR0APCZKKM1K55YH2PQPFM
position_column: done
position_ordinal: ff9d80
title: 'Sub-agent sessions 1/4: child session tree and routing'
---
## What
Part 1 of 4 of the split of this card. Parts 2 (resume and confirmation), 3 (derived views) and 4 (restore failure) depend on this card. This card builds the tree and the routing only.

Rule of the model (user decision, 2026-11-03): it is parent and child all the way down. Every session is the same kind of thing. Depth is not a case, and no depth is a limit. Each rule below holds at every level. A test chain of three sessions is only a test size.

The agent will announce each sub-agent as an ACP child session (ACP v2 Subagent Sessions RFD: `subagent_update`, child `sessionId` on every update and request, `state_update` per child, `session_message`). The client must collect the root sessions AND the nested child sessions into one observable model.

WAITS FOR the wire cards on the FoundationModelsACP board (other board, so not in depends_on): re-vendor 01M6GJ8GX6C0YRHJW0W2ADAVTE, wire types 01M6GJ664BHY454C5NFPFCSP79 (`subagentUpdate`, `sessionMessage`, child `capabilities`). The SAH meta card 01M6GP1QC785QS2BS3TNVMKT7A is NOT needed by this card.

Today `ConnectionModel` (`Sources/FoundationModelsACPClient/Model/ConnectionModel.swift`) has `sessions: [SessionInfo]` from `session/list` and `openSessions: [SessionModel]`, and routes updates by session id (`SessionModel+Stream.swift`). It has no parent link and no child session.

Change:
- `SessionModel` gets `parent: SessionModel?` (weak), `children: [SessionModel]` (ordered by announce), `title`, `description`, `cwd`, `additionalDirectories`, and `workState` (running, requires_action, unknown, idle with `stopReason`/`error`). All are `@Observable`, so a view can show a session and its children at every level.
- `ConnectionModel` creates a child `SessionModel` on `subagent_update`, before any event of that id. The ancestor chain is announced parent before child. Patch rules: omitted = unchanged, `null` clears, a value replaces; `capabilities` replace as a whole.
- A child is NOT in `sessions` from `session/list`. It is reached through its parent only.
- Updates and agent-to-client requests with a child id (permission, elicitation, file, terminal) go to the child model, not to the parent or the root. A pending request stays attributed to the child.
- The client allows only what the child `capabilities` advertise. Today only `cancel`: `SessionModel.cancel()` on a child sends `session/cancel` with the child id. Prompt, close, delete, fork, load, resume, set mode and set config option on a child are refused locally. Slash commands of a child are not offered.
- A child never ends. It goes `idle`. When a parent is closed, its children are removed.
- `session_message` and `session_message_chunk` go to the transcript of the outer `sessionId`; link sender and recipient views only by `senderMessageId`/`recipientMessageId`.
- An update for an unknown child id with no announcement: keep it unexposed (do not guess a parent).

NOT in this card (see the other parts): replay and resume of children, `isWorkStateConfirmed`, `isClosed`, removal by tool call (part 2); `ancestors`, `siblings`, `descendants`, `SessionPathEntry`, `needsAttention` (part 3); `restoreFailure` (part 4).

## Acceptance Criteria
- [ ] A `subagent_update` creates a child `SessionModel` with `parent` set and the parent `children` updated. A child of a child works by the same rule (test with a chain of three sessions; no code path depends on the depth).
- [ ] `children` is in announce order.
- [ ] Patch rules: an omitted field is unchanged, `null` clears, a value replaces; `capabilities` replace as a whole.
- [ ] Events with the child id reach only the child model.
- [ ] A permission, elicitation, file or terminal request with a child id goes to the child model and stays attributed to the child.
- [ ] `session/list` refresh never adds a child to `ConnectionModel.sessions`.
- [ ] `cancel()` on a child sends `session/cancel` with the child id.
- [ ] `prompt()`, close, delete, fork, load, resume, set mode and set config option on a child throw without sending; slash commands of a child are not offered.
- [ ] `workState` follows `state_update`; `idle` with `stopReason: cancelled` after a cancel.
- [ ] `session_message` and `session_message_chunk` go to the transcript of the outer `sessionId`.
- [ ] Closing a parent removes its children.
- [ ] An update with an unannounced child id changes no model.
- [ ] Observation test: a change of `workState` or `children` fires the `@Observable` tracking.

## Tests
- [ ] `Tests/FoundationModelsACPClientTests/SubagentTreeTests.swift`: all items above. Use the in-process agent (`InProcessAgent.swift`) or a scripted connection.
- [ ] Run `swift test --filter SubagentTreeTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents