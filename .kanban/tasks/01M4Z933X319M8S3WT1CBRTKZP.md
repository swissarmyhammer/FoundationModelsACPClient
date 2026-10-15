---
assignees:
- claude-code
position_column: done
position_ordinal: f280
title: 'T0: Check the new ACPAgent wire behavior from ACPClient'
---
Mail step 6, part T0 (mailbox.md section 8, row 6).

Resolve the packages. Build the library, the tests, IntegrationTests and LiveAgentServer. List each break.

Then compare the client model (SessionModel, ConnectionModel, the transcript entries, PendingElicitation) with the new ACPAgent wire behavior, and list each place where the client assumes the old behavior. Examples: a state update only inside a prompt, an idle always with a stop reason, one open prompt at a time, requires_action, a busySession error, a compaction entry inside a prompt. Report each gap before you change code for it.

The new ACPAgent wire behavior (ACPAgent 293be4b):
- A prompt is mail. The session/prompt response comes at once. Its messageId is the Router MailID (a ULID string). A second prompt while one is open is accepted (no busySession error).
- running and idle come from Router work. running comes when the session gets work or a prompt opens. idle comes when no work and no prompt is left. This also occurs with no prompt open (background work, a compaction). An idle carries the stop reason of the last prompt that ended since the last running, or NO stop reason when only background work ran.
- requires_action is never sent. An open question does not keep the session running.
- session/cancel: the prompt response says cancelled at once. The idle with stop reason cancelled can come later, when model work ends.
- When Router ends an open question (a run cancel, cancelAll, close), ACPAgent ends its elicitation/create request with $/cancel_request.
- /compact returns at once ("Compaction started." with the SignalID). Its entry (in_progress, then completed or failed) comes from the events under the SignalID, after the prompt ended.
- The headless CLI waits for the first idle after the echo of its own messageId.

Heads (all on main): FoundationModelsACPAgent 293be4b, Router 77b2da68, Extras 278e9cb, FoundationModelsACP main.

Rules: STE text. Commit after the task with ACPClient green. Report the commit, the test result and each difference from the plan with its reason. #mail-step-6