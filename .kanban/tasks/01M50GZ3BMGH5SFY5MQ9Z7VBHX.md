---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50h8kkrksefq70x3d08yj45
  text: |-
    ### implement — changed
    - `SessionModel.cancel(meta:)`: first `permissions.cancelAll()`, then `cancelPendingElicitations(reason: ACPClient.clientCancelledReason)`, and then `session/cancel`. Each session elicitation gets `{"action":"cancel","_meta":{"reason":"the client cancelled the work"}}`, and its tool-call link is removed.
    - New public constant `ACPClient.clientCancelledReason`.
    - The request-scoped elicitations of the `ConnectionModel` stay pending.
    - Doc of `cancel(meta:)` (option a): no wire guarantee; the answers are correct in each order; a tool can get "the client cancelled the work" or the reason of the agent (for example "run cancelled"), whichever comes first; the other message is safe.
    - Tests: `cancelKeepsPendingElicitations` is now `cancelAnswersEachPendingElicitationWithCancelAndTheClientReason` (the rule changed by decision of the step owner). New: `theReasonOfAClientCancelIsInTheMetaOfTheAnswer`, `aCancelWithNoPendingItemSendsOnlyTheNotification`, `aSessionCancelKeepsTheRequestScopedElicitations`. `aCancelThatFailsToSendStillCancelsThePermissions` is now `...AndTheElicitations`. The test fake got `observeCancels(_:)`.
    - Full run: 555 tests in 44 suites pass. IntegrationTests builds.
  timestamp: 2026-10-15T19:40:12.280829+00:00
position_column: done
position_ordinal: ff8280
title: 'Elicitation phase 3, task 29: SessionModel.cancel(meta:) also answers the pending session elicitations with cancel and a reason'
---
Source: elicitation-plan.md task 29 (done for ACPAgent; the client part is left).

Today `SessionModel.cancel(meta:)` answers each pending permission request with `cancelled`, but each pending session-scoped elicitation stays pending. Decision of the step owner: the cancel also answers each pending session elicitation with `cancel` and a reason in `_meta` (key `ACPClient.elicitationReasonMetaKey`). This occurs before `session/cancel` goes out, in the same order as the permissions.

Steps: design to the step owner first, then code with fixed-order tests, one full run, commit, and push after acceptance.

#elicitation-phase-3