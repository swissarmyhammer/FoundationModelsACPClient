---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m52hhvhdsa3zpdnscdwtnewg
  text: |-
    ### implement + test — green
    - FoundationModelsACP 6a13575 adds AgentSideConnection.requestPermission(_:cancellation:). It is resolved in both packages.
    - No change to Sources. The permission handler of FoundationModelsACP runs in a child Task of the handler task, which inherits the task-locals. SessionModel.awaitPermissionDecision calls the same recordWithdrawal as awaitElicitation, so it reads cancelledByPeer and cancelRequestMeta in the same way.
    - Test: WithdrawnRequestTests.aPermissionThatTheAgentWithdrawsGivesARecordWithTheReason. New test support: MailOrderStubAgent.startPermission(_:cancellation:).
    - Full run (one time): 629 tests in 51 suites pass. IntegrationTests builds.
  timestamp: 2026-10-16T14:23:44.173202+00:00
position_column: done
position_ordinal: ff8c80
title: requestPermission has no cancellation; a withdrawn permission has no reason
---
FoundationModelsACP 47f65c0: `AgentSideConnection.createElicitation(_:cancellation:)` lets an agent put a reason in the `_meta` of its `$/cancel_request`, but `requestPermission(_:)` has no `cancellation:` variant. Thus a `WithdrawnRequest` of a permission request always has `reason == nil`.

The client side already reads `cancelRequestMeta` for both kinds, so no ACPClient code change is necessary for the reason itself.

## To do
- Upstream (FoundationModelsACP): add `requestPermission(_:cancellation: OutboundCancellation)`.
- ACPClient: add a test where the agent withdraws a permission with a reason, and expect `withdrawnRequests.first?.reason` to be that reason. Use `MailOrderStubAgent`, and add a `startPermission(_:cancellation:)` to it.

Accepted as a known gap with 6e2332b (^z4fanf1). #gap