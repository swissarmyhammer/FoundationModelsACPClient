---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73hkw680206xt7aqcz1s641
  text: |-
    ### review — clean
    - evidence: review sha 89619da~1..89619da — 0 findings (confirmed 0, refuted 0, attempted 7, failed 0, skipped 0); 3 files reviewed.
    - resume check: `OpeningTicket` has only one user, `newSession`. `resumeInTurn` calls `register(session)` and `attachToEvents(session)` BEFORE the `session/resume` request goes out. Thus each event of the session that the consumer applies after that time goes directly to the model, and `attachToEvents` drains the events that the consumer kept before. The replay ends at the marker in the ordered stream. The resume path does not have the race. The child path (`ConnectionModel+Subagents.swift`) attaches in the consumer when it applies the announcement, so it is in the order of the stream too.
    - next: none. The task moves to done.
  timestamp: 2026-11-10T20:15:28.456959+00:00
- actor: claude-code
  id: 01m73hme2fv98t2afyn5yqy039
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files, in worktree branch worktree-agent-a4015841328e157d9 (25760d1), cherry-picked to main
    - cause: `newSession` attached the model at the answer, but did not wait for the consumer to apply the events read before the answer. Fix: the `onResponse` hook records `latestEventSequence` in the `OpeningTicket`, and `newSession` awaits `waitUntilApplied` before `attachToEvents`.
    - test: green — swift test 864/864 x3 on main (and x5 in the worktree); IntegrationTests 28/28
    - commit: 89619da (pushed)
    - review: clean — 0 findings; `resumeInTurn` and the child path have no such gap; task in done
  timestamp: 2026-11-10T20:15:46.767839+00:00
position_column: done
position_ordinal: ffaf80
title: 'Unit tests: aReplayFromTheStartAfterAnOverflowClearsTheMissedUpdatesMark sometimes fails at `try #require(session.hasMissedUpdates)` in the full run'
---
## What
In one full `swift test` run (2026-11-10, during task ^9fjefgg), `ConnectionModelSessionTests.aReplayFromTheStartAfterAnOverflowClearsTheMissedUpdatesMark` failed at `try #require(session.hasMissedUpdates)`. The suite alone passed.

Probable cause (not proved): the stub agent sends two `session/update` notifications before the `session/new` answer, with a buffer limit of one update. The model marks missed updates only when the event consumer task buffers both events before `newSession` calls `attachToEvents(session)`. `newSession` does not wait until the event consumer applied each event that the connection read before the answer. When the answer is processed first, the events go straight to the model, no overflow occurs, and `hasMissedUpdates` stays `false`. The sibling test `moreUpdatesThanTheBufferBeforeTheAnswerMarkMissedUpdates` has the same shape.

## Acceptance Criteria
- [x] Find the cause of the race, and make the result deterministic (for example: `newSession` waits until the events that came before the answer are applied, as the router does with `waitUntilApplied`).
- [x] Both tests pass in each full run. #flaky