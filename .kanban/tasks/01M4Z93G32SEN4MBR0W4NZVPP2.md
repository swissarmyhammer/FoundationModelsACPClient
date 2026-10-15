---
assignees:
- claude-code
depends_on:
- 01M4Z939HBTNVJ8F4X94C99WW9
position_column: todo
position_ordinal: '8280'
title: 'T2: The client model follows the new ACPAgent wire behavior'
---
Mail step 6, part T2 (mailbox.md section 8, row 6).

Change the client model (SessionModel, ConnectionModel, the transcript entries, PendingElicitation) so that it follows the new ACPAgent wire behavior. Make one change for each gap of T0 that the step owner accepts. Each change has a fixed-order test.

Possible gaps (from the plan): state updates with no prompt open, an idle with no stop reason, more than one open prompt, no requires_action, the $/cancel_request of an elicitation, the messageId of a prompt, a compaction entry that comes after the prompt ended.

Rules: STE text. Tell the step owner the change for each gap. If a gap needs a real choice, ask first. No .timeLimit, sleep, clock wait, poll or retry in a test. Commit after the task with ACPClient green. Report the commit, the test result and each difference from the plan with its reason. #mail-step-6