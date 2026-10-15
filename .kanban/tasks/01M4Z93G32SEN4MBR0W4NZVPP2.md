---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4zaz9cmjjvfy6xspzen1hmm
  text: |-
    ### implement — changed
    - No source change: the model already follows the new wire behavior (T0). T2 adds the fixed-order tests for G2, G3 and G4.
    - New `Tests/.../MailOrderStubAgent.swift`: a stub with the 293be4b order (the prompt answers at once with the next message id; the test sends each update itself; `session/cancel` sends nothing and is given on `cancels`; `startElicitation` sends `elicitation/create`, and its cancel sends `$/cancel_request`). Difference from G2: a new stub, not an option on `ScriptedStubAgent`; the old stub stays as it is for the old-order tests.
    - New `Tests/.../ObservationWait.swift`: `waitForObservation(until:)`, a wait with `withObservationTracking`, no clock, no poll (also for T3).
    - New `Tests/.../Model/SessionModelMailOrderTests.swift`, 5 tests: G2 link by the answer id, echo after the answer adds no entry; G3(1) running + compaction + idle with no stop reason after the prompt ended; G3(2) two open prompts, echoes in the other order; G3(3) cancel: the session stays running until the later idle `cancelled`; G4 `$/cancel_request` removes the pending elicitation.
    - Note for G3(3): `PromptResponse` of alpha.8 has only `messageId`, so the client cannot see "cancelled" in the prompt answer. The test checks the later idle.
    - evidence: `swift test`: 538 tests pass (1 run).
  timestamp: 2026-10-15T08:31:01.012889+00:00
depends_on:
- 01M4Z939HBTNVJ8F4X94C99WW9
position_column: done
position_ordinal: f880
title: 'T2: The client model follows the new ACPAgent wire behavior'
---
Mail step 6, part T2 (mailbox.md section 8, row 6).

Change the client model (SessionModel, ConnectionModel, the transcript entries, PendingElicitation) so that it follows the new ACPAgent wire behavior. Make one change for each gap of T0 that the step owner accepts. Each change has a fixed-order test.

Possible gaps (from the plan): state updates with no prompt open, an idle with no stop reason, more than one open prompt, no requires_action, the $/cancel_request of an elicitation, the messageId of a prompt, a compaction entry that comes after the prompt ended.

Rules: STE text. Tell the step owner the change for each gap. If a gap needs a real choice, ask first. No .timeLimit, sleep, clock wait, poll or retry in a test. Commit after the task with ACPClient green. Report the commit, the test result and each difference from the plan with its reason. #mail-step-6