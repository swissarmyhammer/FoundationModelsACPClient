---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7wj29adrpaq6s3r7bmzvc7n
  text: |-
    Research (implement step).

    Client:
    - `SessionModel.background` (Sources/FoundationModelsACPClient/Model/SessionModel.swift, the `background` computed property) gives the `background` list of `agentState` as the agent sent it. Only a `state_update` changes it. A `tool_call_update` does not change it.
    - The child closes on the final status of its linked `agents` call: `SessionModel.refreshChildLinks()` (Model/SessionModel+Subagent.swift, `removeFromParent()` for each child whose `startedByToolCallId` has a final status). The stream calls it after each entry change.

    Agent (FoundationModelsACPAgent 090f1c2, read only):
    - `BackgroundWatch.reporting(sentThrough:to:)` (Agent/BackgroundWatch.swift:84-88) sends the update first (`await sink(update)`), and only then reports `.callSettled` to the ledger. `BackgroundBook` (Agent/BackgroundBook.swift:6-7) says: "it drops the item after its final status". `SessionStateLedger.background(_:)` (Agent/PromptState.swift:329-332) then sends a new `state_update` with the shorter list.
    - Thus the wire order of the end of a background `agents` call is: (1) `tool_call_update` with the final status, (2) `state_update` with no call. The client closes the child at (1) and drops the call at (2). Between (1) and (2) the root lists the call of a closed child.
    - Wire evidence: scratchpad trace2.log of 2026-11-19 (cancel of the first child), root session ...ESQSGQ: line 414 `tool_call_update scripted-call-1 completed`, line 415 `state_update running [subagent child-2]`. The call leaves the list one message after its final status.
    - The order is by design and cannot be one message: ACP has no update that carries a status and a state together. If the agent sent the state first, the list would drop a call that is still `in_progress`, and an idle session would show the call as stale for one message.

    Second discovery (agent defect, not the observed case): `ACPEventTranslator.closeCancelledRun(of:)` (Agent/ACPEventTranslator.swift:266-278) and `closeDetachedCalls()` (Agent/SessionProjector.swift:774-779) send a final `cancelled` status with no settlement. `BackgroundWatch.changes(afterSending:)` (Agent/BackgroundWatch.swift:155) reports `.callSettled` only for a run with `isSettling`, which only a `runSettled` event of kind `completed` sets (:96-99). So after a root cancel the book keeps the call, and each later `state_update` still lists it. Wire evidence: trace2.log lines 430-431: `state_update idle [scripted-call-2]`, then `tool_call_update scripted-call-2 cancelled`, and no later state drops it.

    Decision: step 2 applies. The call stays in `background` after its final status. The client fix: `background` drops each `tool_call` item whose transcript entry has a final status. This is a view of the data that the model has; it adds no state. The cancel defect goes to the agent session in a brief.
  timestamp: 2026-11-20T13:24:21.453364+00:00
- actor: claude-code
  id: 01m7wj8ydqk5r5tgct3hjdswrj
  text: |-
    Implementation landed (not committed).

    Cause: the agent wire order of the end of a background call is (1) `tool_call_update` with the final status, then (2) `state_update` with the shorter list (FoundationModelsACPAgent Agent/BackgroundWatch.swift:84-88, Agent/BackgroundBook.swift:6-7; trace2.log of 2026-11-19, lines 414-415). The client closed the child at (1) (`SessionModel.refreshChildLinks()`), but `SessionModel.background` mirrored the agent list and dropped the call only at (2). This order is correct for the agent (ACP has no update with a status and a state together), so the fix is in the client (step 2).

    Change:
    - Sources/FoundationModelsACPClient/Model/SessionModel.swift: `background` drops each `tool_call` item whose transcript entry has a final status (new private `isFinishedToolCall(_:)`, which uses `toolCallEntry(for:)`). It is a view of data the model has. No new stored state, no event.
    - Tests/FoundationModelsACPClientTests/Model/BackgroundToolCallTests.swift: `aFinalStatusRemovesTheCallFromTheBackgroundList`.
    - Tests/FoundationModelsACPClientTests/SubagentResumeTests.swift: `theFinalStatusThatClosesAChildRemovesItsCallFromTheBackgroundList` (stub agent sends the agent wire order; after the child closes, the root list is empty).
    - RED: both failed with the call still in `background`. GREEN: both pass.
    - `swift test`: 963 tests in 79 suites passed. The only warning is the MLX "missing creator for mutated node" warning.

    Brief: the cancel defect (a final `cancelled` from `closeCancelledRun(of:)` or `closeDetachedCalls()` gives no `.callSettled`, so the agent lists the call for good) is in /Users/wballard/github/swissarmyhammer/.briefs/acpagent-agents-call-final-order.md. No cross-session message was sent. The client fix hides it in this client, but the agent still keeps the session active (PromptState.swift:422), so the parent lists the child.

    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPClient/Model/SessionModel.swift, Tests/FoundationModelsACPClientTests/Model/BackgroundToolCallTests.swift, Tests/FoundationModelsACPClientTests/SubagentResumeTests.swift; brief .briefs/acpagent-agents-call-final-order.md; `swift test` 963 passed, MLX warning only
    - next: /review
  timestamp: 2026-11-20T13:27:59.671073+00:00
- actor: claude-code
  id: 01m7wkzbq79byzhzgxrmy0j1kj
  text: |-
    ### test - stuck
    - evidence: `swift test` (root package only) - 963 tests in 79 suites passed, 0 failed, 0 skipped. No warning comes from Sources or Tests.
    - blocker: the build output holds warnings that are not allowed. They come from code outside this repository.
      - `-Wc++17-extensions` warnings from the mlx-swift checkout, files `complex.h` and `utils.h` (the Metal shader build). A fix needs a change in the dependency or C++ interoperability. The rules forbid both.
      - SwiftPM "skipping cache due to an error: The file maintenance.lock doesn't exist" for 7 packages. SwiftPM made fresh working copies in this run. This is a state of the SwiftPM cache on the machine. It is not a defect in the project code.
      - The one allowed warning is also present: "missing creator for mutated node" for mlx-swift_Cmlx.bundle.
    - next: a person decides if these dependency warnings are allowed.
  timestamp: 2026-11-20T13:57:42.759387+00:00
- actor: claude-code
  id: 01m7wm0qk34zps1mj50kxsh2cv
  text: |-
    ### test — green
    - evidence: the orchestrator ran `swift test` again on the root package, on top of the first build: 963 tests in 79 suites pass. The build output has only the allowed MLX "missing creator for mutated node" warning. The C++17 warnings (mlx-swift Metal shaders) and the SwiftPM "maintenance.lock" cache warnings came only from the fresh build of the dependency checkouts in the first run. They are not from this repo, and a run on top of that build does not show them. The other "warning" lines are log output that the tests expect.
    - next: commit
  timestamp: 2026-11-20T13:58:27.683635+00:00
position_column: doing
position_ordinal: '80'
title: 'Examine: the agents call of a closed child stays in the root background list for a time'
---
## Observation

During ^xdffmdm (2026-11-20), a temporary test wait for the FIRST child's `agents` call in the root's `SessionModel.background` list passed AFTER that child had closed (`first.isClosed` was true). Thus the call stays in the background list for some time after its child closes. Source: the implement step of ^xdffmdm, recorded on that card.

## Question

Is this correct? Commit 41cd2c4 ("a background tool call stays busy until its real end") keeps a background tool call in the list until its real end (its final `tool_call_update`). The child closes when its linked `agents` call gets a final status. If both come from the same final update, the call must leave the list at the same time as the child closes, or the list shows finished work as running (a view shows a busy item for a closed child).

## Change

1. Examine the order: which update closes the child, and which update removes the call from `background`. Use a unit test with a scripted agent (no live integration run).
2. If the call stays in `background` after the final status of the call, fix the model so that the final status removes it, and add a test.
3. If the agent sends the final status of the call later than the close of the child (a wire order), record the evidence and send a brief to the FoundationModelsACPAgent session; do not change the client.
4. Do not add a busy state, turn state or event (rule of this repo).

## Acceptance

- [x] The cause is recorded with evidence (file:line, wire order).
- [x] If the client is wrong: a test shows the call leaves `background` with its final status, and `swift test` passes. The only allowed warning is the MLX "missing creator for mutated node" warning.