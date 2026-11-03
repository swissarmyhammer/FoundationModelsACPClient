---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: End-to-end acceptance tests of the sub-agent model against the real acp-agent
---
## What
Three tests in IntegrationTests/Tests/.../AgentNestedRunTests.swift drive the REAL acp-agent binary (built through the LiveAgentServer package) with the scripted stub model (ACP_AGENT_STUB_SCRIPT, a JSON file; the agent package task 01M6H6QWVCRM2QT95WMXC77XQP). They are expected to fail until the agent package lands the scripted stub: each body runs inside withKnownIssue. When the agent passes a test, withKnownIssue fails it, and the marker must be removed.

## Assertions (each one is checked in a test)
Test 1: aNestedRunOfTheRealAgentBuildsAndEmptiesTheTree
- [ ] 1. The tree appears: the root has one child, the child has one grandchild (parent, children, descendants).
- [ ] 2. The events of each run are in its own model (the child transcript has the child text, the grandchild transcript has only the grandchild text).
- [ ] 3. The grandchild runs while it waits at the gate (workState running).
- [ ] 4. The agents call of the root links the child (ToolCallEntry.childSession).
- [ ] 5. At the final tool call update each child is removed (isClosed, children empty).
Test 2: aKilledAgentResumesTheNestedRunWithItsTree
- [ ] 7. After the process ended and a new process resumed the root with replayFrom start, the tree comes back.
- [ ] 8. A child is unconfirmed until its current snapshot after the response, then confirmed.
- [ ] 9. The interrupted runs continue when the gate opens.
- [ ] 10. The original agents call completes, and the children are removed.
Test 3: theNestedRunTraceFollowsTheWireRules
- [ ] 6. The recorded ordered trace has zero violations of SubagentWireTraceValidator, and it holds a subagent_update.

## Script format (agent contract)
ACP_AGENT_STUB_SCRIPT = path of a JSON file: {"sessions":[{"match":{"promptContains":"..."},"passes":[[steps],[steps]]}]}. Steps: {"text"}, {"reasoning"}, {"toolCall":{"name":"agents","arguments":{...}}}, {"gate":"<path>"}. Agent definitions are written to <workspace>/.agents/agents/<name>/AGENT.md by the test.

## Workflow
- Use /tdd. Red first (the tests are red on purpose). #subagents