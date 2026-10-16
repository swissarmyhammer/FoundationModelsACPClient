---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: requestPermission has no cancellation; a withdrawn permission has no reason
---
FoundationModelsACP 47f65c0: `AgentSideConnection.createElicitation(_:cancellation:)` lets an agent put a reason in the `_meta` of its `$/cancel_request`, but `requestPermission(_:)` has no `cancellation:` variant. Thus a `WithdrawnRequest` of a permission request always has `reason == nil`.

The client side already reads `cancelRequestMeta` for both kinds, so no ACPClient code change is necessary for the reason itself.

## To do
- Upstream (FoundationModelsACP): add `requestPermission(_:cancellation: OutboundCancellation)`.
- ACPClient: add a test where the agent withdraws a permission with a reason, and expect `withdrawnRequests.first?.reason` to be that reason. Use `MailOrderStubAgent`, and add a `startPermission(_:cancellation:)` to it.

Accepted as a known gap with 6e2332b (^z4fanf1). #gap