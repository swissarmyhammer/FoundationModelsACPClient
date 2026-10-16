---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m51wj7bxvk0psfked7qrw58y
  text: |-
    ### implement — changed (design accepted by the step owner)
    - `ConnectionModel.frontRequestID` (public internal(set)), `frontRequest` and `bringToFront(_:)`, in the new file `ConnectionModel+Front.swift`. The behavior is the same as on SessionModel.
    - The `didRemove` hook of the elicitation queue clears the pointer, so it becomes nil when its request is answered or cancelled, at a close and at a new connection.
    - Test harness change: `LoginHarness.startElicitation(naming:)` now waits for one more pending item, so a test can start more than one elicitation.
    - 7 new tests in `ConnectionModelElicitationTests` (MARK Front).
    - Full run: 596 tests in 47 suites pass.
  timestamp: 2026-10-16T08:16:56.189209+00:00
position_column: done
position_ordinal: ff8780
title: 'Elicitation phase 6, task 51: frontRequest and bringToFront(_:) on ConnectionModel, with the behavior of SessionModel'
---
Source: request of the step owner. The AgentViewKit request deck (its task 34) waits for this task.

Work:
- ConnectionModel gets `frontRequestID`, `frontRequest` and `bringToFront(_:)`, with the behavior of SessionModel (task 31, 7676d81).
- FIFO over `pendingRequests`. A new request goes at the back and does not change the front.
- After the front is answered or cancelled, the front is the oldest request that stays.
- Tests in fixed order, with no time limit, sleep, poll or retry.
- One full run. Push together with task 52, after the CI run of 682e997 ends.

#elicitation-phase-6