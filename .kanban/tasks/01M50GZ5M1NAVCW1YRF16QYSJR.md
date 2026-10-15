---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50hga3xczhgfv6es5v5fdx6
  text: |-
    ### implement — changed
    - New `public enum PendingRequest: Identifiable, Hashable, Sendable` with `permission(PendingPermissionRequest)` and `elicitation(PendingElicitation)`. The id is the UUID of the item.
    - `PendingArrivalCounter` (main actor) gives each item a number when its call suspends. `PendingRequestQueue` records the number and gives `requestsWithArrival(_:)`.
    - `SessionModel.pendingRequests` merges both queues in arrival order. `ConnectionModel.pendingRequests` has the same shape and holds the request-scoped elicitations.
    - The typed lists `pendingPermissions` and `pendingElicitations` do not change.
    - Tests: `pendingRequestsGivesBothKindsInArrivalOrder` (P1, E1, P2), `aResolutionKeepsTheOrderOfTheOtherRequestsAndTheTypedLists`, `anArrivalAndAResolutionEachFireTheObservationOfPendingRequests`, `pendingRequestsGivesEachRequestScopedElicitationInArrivalOrder`.
    - Full run: 559 tests in 44 suites pass. IntegrationTests builds.
  timestamp: 2026-10-15T19:44:24.701469+00:00
position_column: done
position_ordinal: ff8380
title: 'Elicitation phase 6, task 30: one FIFO list of the pending permissions and elicitations of a session'
---
Source: elicitation-plan.md task 30 and section 4 (one deck, one FIFO order by arrival time).

Today a session model has two separate lists: `pendingPermissions` and `pendingElicitations`. The request deck needs one list in arrival order. The connection model holds the request-scoped elicitations.

Steps: design to the step owner first (it must say what happens to the current lists), then code with fixed-order tests, one full run, commit, and push after acceptance.

#elicitation-phase-6