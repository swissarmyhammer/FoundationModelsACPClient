---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: 'IntegrationTests: anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall sometimes exceeds its 120 s limit in the full run'
---
## What
On 2026-11-10, one full run of `swift test --package-path IntegrationTests` failed. `anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall` in `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentNestedScenarioTests.swift` gave "Time limit was exceeded: 120.000 seconds". The same test alone passed in 29.7 s, and the next full run passed 23/23 in 64.8 s. The code under test did not change between the runs (the change at that time was a refactor of the default methods of `ClientModelExtension`). Find the cause: a slow agent start when the suites run together, a wait with no end event, or contention between the agent processes. Then correct it.

## Acceptance Criteria
- [ ] The cause is found and written in the task.
- [ ] The test does not exceed its limit in 10 full runs in a row of `swift test --package-path IntegrationTests`.
- [ ] No sleep, poll or larger time limit hides the cause.

## Tests
- [ ] If the cause is a missing end event, add the event to the wait in `AgentNestedScenarioTests.swift`, so a failure ends at once with a message.
- [ ] Run `for i in $(seq 10); do swift test --package-path IntegrationTests || break; done` → 10 passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #flaky