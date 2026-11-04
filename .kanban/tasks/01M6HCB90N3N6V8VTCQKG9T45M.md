---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6hva5c1dewrp1snbk5ny2pa
  text: |-
    ### finish — stuck
    - evidence: The five tests are red on purpose. They need the agent package behavior for cancel, child requests, hot resume, restart and SIGTERM, and the elicit stub step. Not on agent origin/main yet.
    - next: After the agent lands that work, update the pin in IntegrationTests/LiveAgentServer, run each test alone, and review. The tests must not change to become green.
  timestamp: 2026-11-03T23:18:36.161790+00:00
- actor: claude-code
  id: 01m6kz1datf822km3b6gx87e3v
  text: |-
    ### implement — changed
    - evidence: same change as ^az95nem: 2 files — AgentNestedRunTests.swift and AgentNestedScenarioTests.swift in IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/. The .bug trait is removed from all 8 tests; .timeLimit(.minutes(2)) is kept; the headers say that the tests run the real acp-agent-stub and must pass. Build complete; 1 test run (aNestedRunOfTheRealAgentBuildsAndEmptiesTheTree) passed.
    - boxes ticked: A1, A3, A4, A5, B4, C1 to C4, D1 to D3, E1 to E4. C5 stays as NOT TESTABLE.
    - boxes open, with the gap in the test: A2 (no check that the linked tool call of the cancelled child ends); B1 and B2 (no permission request in the test: the agent sends none); B3 (the test accepts the question, it does not decline it; the pending-once part is checked).
    - next: /review. A person must decide if the open items need new tests or a change of the card.
  timestamp: 2026-11-04T19:02:12.570532+00:00
- actor: claude-code
  id: 01m6kzcr82eda4dbs5cfxtr0z2
  text: |-
    B1 and B2 are BLOCKED. The stub script of the agent (FoundationModelsACPAgent at pin bb8cc3b, file Sources/FoundationModelsACPAgent/Configuration/ScriptedStubScript.swift) has these steps only: text, reasoning, toolCall, gate, elicit. It has NO permission step. No code in Sources of the agent package calls requestPermission. Missing agent feature: a script step {"permission": "<title>"} that makes the stub run send a session/request_permission to the client, wait for the outcome, and go on (text after an allow). No test was faked. B1 and B2 stay unticked.

    Done in this pass: A2 (aCancelOfOneChildEndsOnlyThatChild now checks that the linked agents call of the cancelled child has a final status, and that the child leaves the tree). B3 (new test aDeclinedChildQuestionEndsTheChildPassWithoutTheTextAfterIt: decline ends the child pass, no text after the question; the question is pending once under the child and never under the root, checked by the shared helper awaitChildQuestion). Each of the changed tests passed alone.

    ### implement — stuck
    - evidence: 4 files changed: IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentNestedScenarioTests.swift, AgentNestedRunTests.swift, IntegrationWait.swift (helper agentsCalls), and the card files. swift build --build-tests: complete. Run alone, all passed: aKilledAgentResumesTheNestedRunWithItsTree, aCancelOfOneChildEndsOnlyThatChild, aChildQuestionShowsUnderTheChildOnceAndItsAnswerReachesIt, aDeclinedChildQuestionEndsTheChildPassWithoutTheTextAfterIt, anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall.
    - stuck on: B1, B2 only (missing agent step "permission").
    - next: the agent package adds the permission step; then write the B1/B2 test.
  timestamp: 2026-11-04T19:08:24.194160+00:00
position_column: doing
position_ordinal: '8180'
title: More end-to-end acceptance tests of the sub-agent model against the real acp-agent
---
## What
Five more tests in IntegrationTests/Tests/.../AgentNestedScenarioTests.swift drive the REAL acp-agent with the scripted stub model (ACP_AGENT_STUB_SCRIPT). Each test records the frames of its connection (TraceTransport) and checks the trace with SubagentWireTraceValidator. They are RED until the agent package lands the scripted stub model and the behavior that each one names. Companion card: 01M6H96QSAMH4C0R7ECAZ95NEM (the first three tests).

Assumed script steps beside the agent contract (text, reasoning, toolCall, gate): {"permission": "<title>"} (the run asks for a permission and waits) and {"elicit": "<message>"} (the run asks a form question and waits). The agent session must confirm or change them.

## Assertions
Test A: aCancelOfOneChildEndsOnlyThatChild
- [x] A1. Two children of the root run, each at its gate.
- [x] A2. cancel() on the first child goes to the child id: it goes idle with stopReason cancelled, and its linked tool call ends (the child is removed). (The test checks the idle state, the final status of the linked call, and that the child leaves the tree.)
- [x] A3. The sibling and the root keep running (workState running, not closed, root not idle).
- [x] A4. cancel() on the parent leaves the running background child running.
- [x] A5. The trace has zero violations.
Test B: aChildRequestShowsUnderTheChildOnceAndItsAnswerReachesIt
- [ ] B1. A permission request of the child is pending under the child id, exactly once, and never under the root (the relayed copy never reaches the client). (BLOCKED: the stub script has no permission step. See the comment of the card.)
- [ ] B2. The answer reaches the child: the run goes on (text after permission). (BLOCKED: the same missing step. The test checks the text after a form answer.)
- [x] B3. A form question of the child is pending under the child once and never under the root; the decline reaches the child. (Test aChildQuestionShowsUnderTheChildOnceAndItsAnswerReachesIt checks the pending question; test aDeclinedChildQuestionEndsTheChildPassWithoutTheTextAfterIt declines it and checks that the child ends its pass without the text after the question.)
- [x] B4. The trace has zero violations.
Test C: aHotResumeKeepsTheRunningChildRunning
- [x] C1. The same connection resumes the live session from the start: the resume returns the same model, the replay is over.
- [x] C2. The tree is the same, each child is confirmed by its current snapshot after the response, the grandchild is still running.
- [x] C3. The run goes on after the resume: the gate opens and the child is removed at the final tool call update.
- [x] C4. The trace has zero violations.
- [ ] C5. NOT TESTABLE with one stdio process: the OLD connection gets no more updates. The agent package must test it with two connections (the agent session decides).
Test D: aChildWithNoDefinitionAfterARestartShowsUnknownWithItsReason
- [x] D1. After a restart with the AGENT.md of the child deleted, the root resumes (its state is current).
- [x] D2. The child and the grandchild are in the tree as unknown, each with restoreFailure.
- [x] D3. The trace has zero violations.
Test E: anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall
- [x] E1. After SIGTERM to the agent process and a new process, the tree comes back, the grandchild runs again.
- [x] E2. The interrupted runs continue when the gate opens.
- [x] E3. The ORIGINAL agents call of the root completes (status completed, not lost).
- [x] E4. The trace has zero violations.

## Workflow
- Use /tdd. Red first (the tests are red on purpose; the .bug trait names this card). #subagents