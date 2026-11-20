---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7vsp4hsppr17ww2z2jx7m8d
  text: |-
    Research (2026-11-20). deec585 removed the frame wait at the old line 250 and `waitForIncomingFrame(containing:)`. No integration test waits on a frame now. Each wait is `waitUntil(_:orFailWhen:)`.

    Waits with a gap (the expected state needs more root work, and the failure event cannot become true when the root ends its turn while a child is still in the tree):
    - AgentNestedScenarioTests `aCancelOfOneChild...`, the wait for two children (`session.children.count == siblingCount`, `orFailWhen: ended`). `sessionEnded` is true only when the root is idle AND has no children. When the root ends its turn after the first start only (the old replay bug), the first child is still in the tree, so the wait goes on until the 120 s limit.
    - Same test, the wait for the agents call of the second child in `session.background` (`orFailWhen: ended`). An idle root that does not list the call in its background list cannot list it later. The agent stamps each state with the background list (FoundationModelsACPAgent PromptState `stamped(_:)`), so an idle root with a background child lists it in the same update.

    Waits with no gap:
    - The waits on child state (running, cancel capability, idle cancelled, closed, pending question or permission, child text): they need no root work. `SessionModel.removeFromParent` removes and closes a child in one main-actor step, so "root idle and no children" implies that the child is closed.
    - The waits after the root cancel (`orFailWhen: rootClosed`): the root turn ends there by design.
    - The resume waits (`orFailWhen: { session.isClosed }`): after a cold resume the root is idle before the snapshots come, so `sessionEnded` would fail at once. The root turn is not part of the expected state.
    - AgentNestedRunTests, NestedSubagentTests (fixed script, resumed root), LiveAgentTurnTests (the wait is for the idle itself, and it ends when the tap ends), GraphQLTunnelTests (no session): no gap.

    Plan: failure event `session.isClosed || isIdle(session)` on the two waits, and a message that names the expected state and the root state. `WaitEndedOnFailure` gets optional `expected` and `observed` text, and `waitUntil` gets two parameters with defaults, so the other callers do not change.
  timestamp: 2026-11-20T06:18:17.529152+00:00
- actor: claude-code
  id: 01m7vtp1575fm90rhwc82am3da
  text: |-
    ### implement — changed
    Discovery (wire trace, scratchpad of session 1f1ff490, `xdff-trace1.txt`): a root with a child in the background does NOT go idle after the last step of its pass. It plays the text "root done" and stays `running` while the child runs. Thus `isIdle(session)` alone cannot see the end of the root pass. The first fix (failure `session.isClosed || isIdle(session)`) still waited 128 s. The observable end of the scripted root pass is its last text.

    Change (test code only):
    - `NestedRunFixture.swift`: new constant `rootFinalText` ("root done"). `NestedScript.rootSession` and `AgentNestedRunTests` use it in place of the literal.
    - `IntegrationWait.swift`: `WaitEndedOnFailure` has the optional fields `expected` and `observed`. `waitUntil` has the parameters `expecting:` and `observed:`, both with a `nil` default, so the other callers do not change. The message is "the wait at <file:line> for <expected> ended on its failure event: <observed>".
    - `AgentNestedScenarioTests.swift`, `aCancelOfOneChild...`: new failure event `rootPassEnded` = root closed, OR root idle, OR the root transcript holds `rootFinalText`, and a `rootState` text (work state, closed, last step played, count of children, count of background items). These two waits use it: the wait for 2 children, and the wait for the agents call of the second child in the root background list. The other waits keep their failure events (each needs no root work, or comes after the root cancel or after a resume).

    Proof of the fast failure (temporary local changes, removed, not committed):
    - RED: script with no reviewer start, old waits: "Time limit was exceeded: 120.000 seconds", 128.0 s.
    - Same script, new waits: failed after 7.5 s: "the wait at .../AgentNestedScenarioTests.swift:251 for 2 children of the root ended on its failure event: the root has the work state running, closed false, last step played true, 1 children, 2 background items".
    - Background wait with a condition that cannot become true: failed after 13.4 s: "... for the agents call scripted-call-2 of the second child in the background list of the root ended on its failure event: the root has the work state running, closed false, last step played true, 1 children, 2 background items".
    - Note: a temporary wait for the agents call of the FIRST child in the background list passed after the first child closed. Thus that call stays in the root background list for some time after its child closed. I did not examine this more.

    Checks:
    - `timeout 1800 swift build --build-tests --package-path IntegrationTests`: exit 0, only the allowed MLX warning.
    - `timeout 1800 swift test --package-path IntegrationTests --filter AgentNestedScenarioTests`: 7 tests in 1 suite passed (32.1 s).
    - `timeout 1800 swift test --package-path IntegrationTests`: 29 tests in 7 suites passed, 1 known issue (WireTraceReportTests), 96 s.
    - `timeout 1800 swift build --build-tests` and `timeout 1800 swift test` (root): exit 0, 961 tests in 79 suites passed, only the allowed MLX warning.
    - No commit, no push. "Push main" stays open. The task stays in doing.
    - next: review.
  timestamp: 2026-11-20T06:35:42.631931+00:00
- actor: claude-code
  id: 01m7vtt0nc54t6x376ryrfv8m4
  text: |-
    ### test — green
    - evidence: `timeout 1800 swift test` exit 0, 961 tests in 79 suites passed. `swift build --build-tests --package-path IntegrationTests` exit 0. `swift test --package-path IntegrationTests --filter "AgentNestedScenarioTests|AgentNestedRunTests"` exit 0, 10 tests in 2 suites passed.
    - warnings: only the allowed MLX "missing creator for mutated node" warning for mlx-swift_Cmlx.bundle. The nested run log also holds runtime logger lines "A session/update send failed" from FoundationModelsACPAgent.PromptExecution. These are log output at teardown, not build warnings. No test failed.
    - no source change made.
    - next: review
  timestamp: 2026-11-20T06:37:53.196447+00:00
- actor: claude-code
  id: 01m7vttrgfw95fy5a0c11fe64d
  text: |-
    ### commit — changed
    - evidence: local commit with the test change and the .kanban changes, subject "test(integration): fail fast when the root plays its last step". Not pushed.
    - next: review
  timestamp: 2026-11-20T06:38:17.615022+00:00
- actor: claude-code
  id: 01m7vtxk0h8apmq473tbemnvby
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (67b7efa). 4 files reviewed. 0 findings, 0 confirmed, 0 refuted. 7 attempted, 0 failed, 0 skipped. 2 .kanban files are not in scope (.reviewignore).
    - next: The task is in done. The "Push `main`" item is still open.
  timestamp: 2026-11-20T06:39:50.289330+00:00
- actor: claude-code
  id: 01m7vtxyahvqz3cswxfk9axkqw
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 test files (AgentNestedScenarioTests, IntegrationWait, NestedRunFixture, AgentNestedRunTests); forced failure now 7.5 s and 13.4 s in place of 128 s
    - test: green — root swift test 961 passed; IntegrationTests build OK; AgentNestedScenarioTests and AgentNestedRunTests 10 passed; only the allowed MLX warning
    - commit: 67b7efa
    - review: clean — 0 findings
  timestamp: 2026-11-20T06:40:01.873074+00:00
position_column: done
position_ordinal: ffc180
title: 'AgentNestedScenarioTests: the wait for the second child call fails fast when the root ends'
---
## Problem

`AgentNestedScenarioTests/aCancelOfOneChildEndsOnlyThatChild()` in `IntegrationTests` waits at `AgentNestedScenarioTests.swift:250` for a frame with the call id `scripted-call-2`. The wait (`WireFrameTrace.swift:87`) has no failure condition. When the frame never comes, the test waits until its 120 s time limit, and the failure tells nothing about the cause.

This occurred in CI runs 44366478943 and 44530736484. The cause is in the scripted stub of FoundationModelsACPAgent: after a Router compaction stop, the stub plays the open pass again from step 1, and the root ends with `_repeated` (see ^epzsg1p and /Users/wballard/github/swissarmyhammer/.briefs/acpagent-scripted-continuation.md). This task does not fix that cause.

## Change

1. Give the wait for `scripted-call-2` (and the other waits for a frame in the same file that can wait without end) a failure condition: the wait fails at once when the root session ends its turn (for example a `stopReason` frame of the root, or `_repeated`) before the expected frame comes. The failure message names the frame that the test expected and the frame that ended the wait.
2. Use the existing helpers of `WireFrameTrace` if possible. Do not add sleeps, polls or `.timeLimit` changes.
3. Comments in STE.

## Tests

- [x] With the fresh pins of `IntegrationTests/LiveAgentServer` (the stub bug still present), `timeout 1800 swift test --package-path IntegrationTests --filter aCancelOfOneChildEndsOnlyThatChild` fails in seconds, not 120 s, with a message that names `scripted-call-2` and the root end. (The stub bug is fixed upstream now. Proof with temporary local changes: see the implement comment of 2026-11-20.)
- [x] The other 27 integration tests still pass.

## Acceptance

- [x] `swift build --build-tests` and `swift test` of the root package pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [x] Push `main`.