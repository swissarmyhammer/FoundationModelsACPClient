---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m52ebt7fqwns3t2c6bca259t
  text: |-
    ### implement — changed (not built: waits for ClientSideConnection.cancelledByPeer)
    - New public `WithdrawnRequest` (id, request, reason). `withdrawnRequests` and `dismissWithdrawn(_:)` on SessionModel and ConnectionModel.
    - PendingRequestQueue.awaitResponse(to:arrival:) now also returns `cancelledByTask`. The onCancel step sets it on the main actor before the call returns.
    - A record is made only when cancelledByTask is true, the model is open, and `cancelledByPeer` is true. The reason comes from `cancelRequestMeta["reason"]`.
    - The list becomes empty at a close, at the start of a resume (through clearNotices), and at a new connection. An empty list is not written, so an observer sees no change.
    - Tests: WithdrawnRequestTests (6 tests), and ConnectionModelElicitationTests.anElicitationThatTheAgentWithdrawsGivesARecordOnTheConnection. The fixed-order close test watches the list with withObservationTracking from before the close until the model is disconnected.
    - Test support: MailOrderStubAgent.startElicitation(_:cancellation:) and startPermission(_:).
  timestamp: 2026-10-16T13:28:00.495377+00:00
- actor: claude-code
  id: 01m52g1t2m22j8s9tx4vjs1rxj
  text: |-
    ### test — green
    - ClientSideConnection.cancelledByPeer is on FoundationModelsACP 47f65c0. The full run passes (628 tests in 51 suites).
  timestamp: 2026-10-16T13:57:29.812809+00:00
position_column: done
position_ordinal: ff8a80
title: 'Cancel reason: withdrawnRequests records each request that the agent withdrew with $/cancel_request, with its reason'
---
Accepted design (peer, P2 names accepted).
```swift
public struct WithdrawnRequest: Identifiable, Hashable, Sendable { id: UUID; request: PendingRequest; reason: String? }
SessionModel / ConnectionModel: public internal(set) var withdrawnRequests: [WithdrawnRequest]; public func dismissWithdrawn(_ id:)
```
- The handler task reads `ClientSideConnection.cancelRequestMeta` (key `reason`) after its call resumes.
- A record is made only when the agent's `$/cancel_request` cancelled the task.

## Blocked
FoundationModelsACP cancels the handler tasks in shutDown() before `closed` fires, so a close cannot be told from a `$/cancel_request` with no `_meta`. The peer asked FoundationModelsACP for `ClientSideConnection.cancelledByPeer: Bool`.

## Tests
- A withdrawal with a reason.
- A withdrawal with no reason.
- A transport close with a pending request gives no record.
- dismissWithdrawn.
- A close empties the list.

Document the two-step change: the item leaves pendingRequests, and then the record arrives.