---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
title: 'Unit tests: aReplayFromTheStartAfterAnOverflowClearsTheMissedUpdatesMark sometimes fails at `try #require(session.hasMissedUpdates)` in the full run'
---
## What
In one full `swift test` run (2026-11-10, during task ^9fjefgg), `ConnectionModelSessionTests.aReplayFromTheStartAfterAnOverflowClearsTheMissedUpdatesMark` failed at `try #require(session.hasMissedUpdates)`. The suite alone passed.

Probable cause (not proved): the stub agent sends two `session/update` notifications before the `session/new` answer, with a buffer limit of one update. The model marks missed updates only when the event consumer task buffers both events before `newSession` calls `attachToEvents(session)`. `newSession` does not wait until the event consumer applied each event that the connection read before the answer. When the answer is processed first, the events go straight to the model, no overflow occurs, and `hasMissedUpdates` stays `false`. The sibling test `moreUpdatesThanTheBufferBeforeTheAnswerMarkMissedUpdates` has the same shape.

## Acceptance Criteria
- [ ] Find the cause of the race, and make the result deterministic (for example: `newSession` waits until the events that came before the answer are applied, as the router does with `waitUntilApplied`).
- [ ] Both tests pass in each full run. #flaky