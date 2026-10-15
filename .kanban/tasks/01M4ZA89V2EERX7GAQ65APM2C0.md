---
assignees:
- claude-code
depends_on:
- 01M4Z939HBTNVJ8F4X94C99WW9
position_column: done
position_ordinal: fa80
title: 'Gap G5: the live test polls for the answer for 30 s after the prompt response'
---
Found in T0. `LiveAgentTurnTests.waitForAgentText(in:)` reads the transcript every 50 ms until it holds agent text, for 30 s at most, and the test has `.timeLimit(.minutes(30))`.

With ACPAgent 293be4b, the prompt response comes at once, and the answer comes later. The poll can stop before the answer of a slow model, and it does not wait for the end of the work.

Change (T3): the test waits with `withObservationTracking` on the session model for the first `idle` that comes after the echo of its own `messageId` (the rule of the headless CLI). Then it checks the agent text and the stop reason `end_turn`. No time limit, no sleep, no poll. #mail-step-6