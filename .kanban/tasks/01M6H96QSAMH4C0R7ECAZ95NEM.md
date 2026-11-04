---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6hva4np69xk4qshw33hwz8b
  text: |-
    ### finish — stuck
    - evidence: The three tests are red on purpose. They need the agent package (scripted stub model, child traffic, agentRun.sessionId link). The stub commit 753dd02 is on agent main. Commit 5c17720 (child traffic and link) is not on agent origin/main.
    - next: After the agent lands 5c17720, update the pin in IntegrationTests/LiveAgentServer, run the tests, and review. The tests must not change to become green.
  timestamp: 2026-11-03T23:18:35.446572+00:00
- actor: claude-code
  id: 01m6kz1axcj3ajzw8ssdd98tq8
  text: |-
    ### implement — changed
    - evidence: 2 files — IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentNestedRunTests.swift, AgentNestedScenarioTests.swift (shared with ^kg9t45m). The .bug trait is removed from all 8 tests; .timeLimit(.minutes(2)) is kept. The file headers now say that the tests run the real acp-agent-stub and must pass. swift build --build-tests: complete (only the allowed mlx-swift_Cmlx.bundle warning). swift test --filter aNestedRunOfTheRealAgentBuildsAndEmptiesTheTree: 1 test passed in 21.795 s. The other 7 tests were not run here (the requester reports that they pass).
    - boxes ticked: items 1 to 9. Item 10 stays open: the test checks that the children are removed, but it does not check the status of the original agents call (test 2 aKilledAgentResumesTheNestedRunWithItsTree).
    - next: /review. No withKnownIssue. Package.resolved not touched.
  timestamp: 2026-11-04T19:02:10.092816+00:00
- actor: claude-code
  id: 01m6kzctpgk9vn8f17azw8kpc6
  text: |-
    ### implement — changed
    - evidence: item 10 is now a test check. aKilledAgentResumesTheNestedRunWithItsTree asserts that the agents calls of the root are not empty and each has status completed, after the resume and the open gate. New helper agentsCalls(in:) in IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/IntegrationWait.swift (also used by the orderly-quit test). Files: AgentNestedRunTests.swift, IntegrationWait.swift, AgentNestedScenarioTests.swift. swift build --build-tests: complete. The test passed alone (41.6 s). The orderly-quit test passed alone after the helper change (38.4 s).
    - next: /review. Card B1/B2 of ^kg9t45m are stuck on the missing permission step of the agent.
  timestamp: 2026-11-04T19:08:26.704294+00:00
position_column: doing
position_ordinal: '80'
title: End-to-end acceptance tests of the sub-agent model against the real acp-agent
---
## What
Three tests in IntegrationTests/Tests/.../AgentNestedRunTests.swift drive the REAL acp-agent binary (built through the LiveAgentServer package) with the scripted stub model (ACP_AGENT_STUB_SCRIPT, a JSON file; the agent package task 01M6H6QWVCRM2QT95WMXC77XQP). They are expected to fail until the agent package lands the scripted stub: each body runs inside withKnownIssue. When the agent passes a test, withKnownIssue fails it, and the marker must be removed.

## Assertions (each one is checked in a test)
Test 1: aNestedRunOfTheRealAgentBuildsAndEmptiesTheTree
- [x] 1. The tree appears: the root has one child, the child has one grandchild (parent, children, descendants).
- [x] 2. The events of each run are in its own model (the child transcript has the child text, the grandchild transcript has only the grandchild text).
- [x] 3. The grandchild runs while it waits at the gate (workState running).
- [x] 4. The agents call of the root links the child (ToolCallEntry.childSession).
- [x] 5. At the final tool call update each child is removed (isClosed, children empty).
Test 2: aKilledAgentResumesTheNestedRunWithItsTree
- [x] 7. After the process ended and a new process resumed the root with replayFrom start, the tree comes back.
- [x] 8. A child is unconfirmed until its current snapshot after the response, then confirmed.
- [x] 9. The interrupted runs continue when the gate opens.
- [x] 10. The original agents call completes, and the children are removed. (The test checks the status completed of each agents call of the root, and that the children are removed.)
Test 3: theNestedRunTraceFollowsTheWireRules
- [x] 6. The recorded ordered trace has zero violations of SubagentWireTraceValidator, and it holds a subagent_update.

## Script format (agent contract)
ACP_AGENT_STUB_SCRIPT = path of a JSON file: {"sessions":[{"match":{"promptContains":"..."},"passes":[[steps],[steps]]}]}. Steps: {"text"}, {"reasoning"}, {"toolCall":{"name":"agents","arguments":{...}}}, {"gate":"<path>"}. Agent definitions are written to <workspace>/.agents/agents/<name>/AGENT.md by the test.

## Workflow
- Use /tdd. Red first (the tests are red on purpose). #subagents