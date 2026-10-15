---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50hsr13tfesx3j19pdy2qj2
  text: |-
    ### implement — changed
    - `SessionModel.frontRequestID: PendingRequest.ID?` (observable), `frontRequest`, `bringToFront(_:)`, and `@discardableResult bringToFront(toolCall:) -> Bool`, in the new file `SessionModel+Front.swift`.
    - `PendingRequestQueue.didRemove` tells the model of each removed item, so the pointer becomes nil when its request resolves. `markClosed()` also sets it to nil.
    - The order of `pendingRequests` does not change.
    - Difference from the design: the setter is `internal(set)`, not `private(set)`, because the extensions in other files set it. The public API stays read-only, as `mcpServers` does.
    - Tests: the new suite `SessionModelFrontTests`, with 9 tests.
    - Full run: 568 tests in 45 suites pass. IntegrationTests builds.
  timestamp: 2026-10-15T19:49:33.859597+00:00
position_column: done
position_ordinal: ff8480
title: 'Elicitation phase 6, task 31: "bring this request to the front" state in the session model'
---
Source: elicitation-plan.md task 31 and section 4. The request deck shows the front card. The "Waiting for your answer" status of a tool call brings its card to the front, and Previous and Next let the user answer in any order.

Steps: design to the step owner first, then code with fixed-order tests, one full run, commit, and push after acceptance. Depends on task 30.

#elicitation-phase-6