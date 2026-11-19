---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
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

- [ ] With the fresh pins of `IntegrationTests/LiveAgentServer` (the stub bug still present), `timeout 1800 swift test --package-path IntegrationTests --filter aCancelOfOneChildEndsOnlyThatChild` fails in seconds, not 120 s, with a message that names `scripted-call-2` and the root end.
- [ ] The other 27 integration tests still pass.

## Acceptance

- [ ] `swift build --build-tests` and `swift test` of the root package pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`.