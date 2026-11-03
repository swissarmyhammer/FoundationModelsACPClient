---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: More end-to-end acceptance tests of the sub-agent model against the real acp-agent
---
## What
Five more tests in IntegrationTests/Tests/.../AgentNestedScenarioTests.swift drive the REAL acp-agent with the scripted stub model (ACP_AGENT_STUB_SCRIPT). Each test records the frames of its connection (TraceTransport) and checks the trace with SubagentWireTraceValidator. They are RED until the agent package lands the scripted stub model and the behavior that each one names. Companion card: 01M6H96QSAMH4C0R7ECAZ95NEM (the first three tests).

Assumed script steps beside the agent contract (text, reasoning, toolCall, gate): {"permission": "<title>"} (the run asks for a permission and waits) and {"elicit": "<message>"} (the run asks a form question and waits). The agent session must confirm or change them.

## Assertions
Test A: aCancelOfOneChildEndsOnlyThatChild
- [ ] A1. Two children of the root run, each at its gate.
- [ ] A2. cancel() on the first child goes to the child id: it goes idle with stopReason cancelled, and its linked tool call ends (the child is removed).
- [ ] A3. The sibling and the root keep running (workState running, not closed, root not idle).
- [ ] A4. cancel() on the parent leaves the running background child running.
- [ ] A5. The trace has zero violations.
Test B: aChildRequestShowsUnderTheChildOnceAndItsAnswerReachesIt
- [ ] B1. A permission request of the child is pending under the child id, exactly once, and never under the root (the relayed copy never reaches the client).
- [ ] B2. The answer reaches the child: the run goes on (text after permission).
- [ ] B3. A form question of the child is pending under the child once and never under the root; the decline reaches the child.
- [ ] B4. The trace has zero violations.
Test C: aHotResumeKeepsTheRunningChildRunning
- [ ] C1. The same connection resumes the live session from the start: the resume returns the same model, the replay is over.
- [ ] C2. The tree is the same, each child is confirmed by its current snapshot after the response, the grandchild is still running.
- [ ] C3. The run goes on after the resume: the gate opens and the child is removed at the final tool call update.
- [ ] C4. The trace has zero violations.
- [ ] C5. NOT TESTABLE with one stdio process: the OLD connection gets no more updates. The agent package must test it with two connections (the agent session decides).
Test D: aChildWithNoDefinitionAfterARestartShowsUnknownWithItsReason
- [ ] D1. After a restart with the AGENT.md of the child deleted, the root resumes (its state is current).
- [ ] D2. The child and the grandchild are in the tree as unknown, each with restoreFailure.
- [ ] D3. The trace has zero violations.
Test E: anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall
- [ ] E1. After SIGTERM to the agent process and a new process, the tree comes back, the grandchild runs again.
- [ ] E2. The interrupted runs continue when the gate opens.
- [ ] E3. The ORIGINAL agents call of the root completes (status completed, not lost).
- [ ] E4. The trace has zero violations.

## Workflow
- Use /tdd. Red first (the tests are red on purpose; the .bug trait names this card). #subagents