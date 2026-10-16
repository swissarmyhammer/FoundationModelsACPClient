---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m52cewdhekmcs4v19kv14tr2
  text: |-
    ### implement — changed (not built yet)
    Design accepted by the peer (Q1 yes, the FoundationModelsACP session makes the upstream part; Q2 no seam; Q3 ACP pushes first).
    - PendingRequestQueue.awaitResponse(to:arrival:): stores the given arrival (else PendingArrivalCounter), and inserts the item before the first item with a larger number.
    - SessionModel.awaitPermissionDecision(for:arrival:afterResponse:), SessionModel.awaitElicitation(_:arrival:), ConnectionModel.awaitRequestScopedElicitation(_:requestId:arrival:).
    - ModelClient reads ClientSideConnection.currentRequestArrival as the first statement of requestPermission and createElicitation, and sends it down.
    - Tests: PendingWireOrderTests (T1 on SessionModel, T2 over the wire with one write of two permissions and one elicitation); ConnectionModelElicitationTests.anElicitationWithASmallerArrivalGoesInFrontOfTheOneThatCameFirst (T1 on ConnectionModel).
    - next: when FoundationModelsACP main has currentRequestArrival, resolve, build, run the full suite one time, commit.
  timestamp: 2026-10-16T12:54:43.889420+00:00
- actor: claude-code
  id: 01m52g1r73e2qwwc0ecatv7bva
  text: |-
    ### test — green
    - FoundationModelsACP resolved at 47f65c0. Full run (one time): 628 tests in 51 suites pass.
    - T1 SessionModel: PendingWireOrderTests.aRequestWithASmallerArrivalGoesInFrontOfTheRequestsThatCameFirst. T1 ConnectionModel: ConnectionModelElicitationTests.anElicitationWithASmallerArrivalGoesInFrontOfTheOneThatCameFirst. T2 wire: PendingWireOrderTests.requestsInOneWriteArePendingInWireOrder (it uses the shared RawBurstAgent).
    - One commit together with ^z4fanf1 and ^g38we5r, because they change the same files.
  timestamp: 2026-10-16T13:57:27.907205+00:00
position_column: done
position_ordinal: ff8980
title: 'Bug: pendingRequests is not in wire order when the agent sends several requests together'
---
Finding from AgentViewKit (deck card 36). elicitation-plan.md section 4 and task 30 (50ce00c) say: the deck is FIFO by arrival time. The arrival order must be the wire order.

## Cause (code read)
- FoundationModelsACP `Connection.readFrames` reads the frames in order and calls `dispatchRequest` one at a time on the actor. `dispatchRequest` takes `nextInboundToken` in wire order, and starts one `Task` for each request.
- In the client, the order is set later. `PendingRequestQueue.awaitResponse(to:)` takes `PendingArrivalCounter.next()` and appends in `onSuspend`, when the task gets to the main actor.
- The tasks run concurrently. They also do a different number of hops before the queue: `createElicitation` first does `await model?.refusedElicitationReason`, and the permission path does `openSession(waitingWhileOpening:)`. Thus two permissions and one elicitation in one write can get to the queue in a different order.
- No public API gives the wire order to a handler.

## Design (not accepted yet)
1. Upstream (FoundationModelsACP): put the inbound sequence number (the `nextInboundToken` of `dispatchRequest`) in a task-local, and expose it as a public read, for example `ClientSideConnection.currentRequestArrival: UInt64?`.
2. ModelClient: read it at the start of `requestPermission` and `createElicitation`, before the first `await`. Send it down to `awaitPermissionDecision`, `awaitElicitation` and `awaitRequestScopedElicitation`.
3. PendingRequestQueue: store the given arrival. Insert the item at its position by arrival, not at the end. The typed lists and `pendingRequests` of SessionModel and ConnectionModel then all use the wire order.
4. Without a request task (previews, direct tests), use a local counter.

## Tests
- T1, fixed order, fails on the old code every time: give a SessionModel arrivals 2 (permission), 3 (elicitation), then 1 (permission). Expect order 1, 2, 3. The old code gives 2, 3, 1. Do the same for ConnectionModel.
- T2, wire: the agent sends two permissions and one elicitation in one write. Wait on observation until there are 3 items. Expect the wire order.

## Acceptance
- The order of pendingRequests is the wire order on both models.
- No time limit, sleep, poll or retry. Full suite green, one run. #bug