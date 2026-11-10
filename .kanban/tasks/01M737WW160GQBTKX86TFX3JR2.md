---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73a0wcvxdypzpshdq5t1p52
  text: 'A sibling test has the same fault. On 2026-11-10, during task ^9fjefgg, `aKilledAgentResumesTheNestedRunWithItsTree` (`AgentNestedRunTests.swift`) gave "Time limit was exceeded: 120.000 seconds" in 2 of 5 full runs of `swift test --package-path IntegrationTests`. The other 3 full runs passed 23/23 in about 70 s. Its suite alone passed 2 of 2, and the test took 2.3 s to 2.6 s each time. In the failed runs the test did its `session/resume` with the replay, and then a wait did not end. The session did not close, so `orFailWhen` did not stop the wait. Fix both tests with the same cause.'
  timestamp: 2026-11-10T18:02:46.043771+00:00
- actor: claude-code
  id: 01m73asrrcnckfsxjnt5pqwmw8
  text: |-
    ### more flaky integration tests (2026-11-10)
    - `aHotResumeKeepsTheRunningChildRunning()` failed in 1 of 3 full runs at HEAD a58423a, and in 1 of 3 runs with the uncommitted work of 01M73039GY. It fails with `Expectation failed: violations.isEmpty` at `AgentNestedScenarioTests.swift:60:9`. The `SubagentWireTraceValidator` reports `announceBeforeUse`, `noHistoricalStateAsCurrent` and `backgroundList` at trace positions 16 and 17 ("an update in <session> before it is announced"). This is an order fault, not a timeout.
    - `aKilledAgentResumesTheNestedRunWithItsTree` went over its 120 s limit in 2 of 5 full runs during 01M73039GY.
    - Thus the nested scenario suite fails often in a full run. CI runs this package, so CI can be red when the code is correct. Correct this task before the next big change.
  timestamp: 2026-11-10T18:16:21.516723+00:00
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