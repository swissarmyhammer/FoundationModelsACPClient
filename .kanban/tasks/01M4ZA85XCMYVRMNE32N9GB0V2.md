---
assignees:
- claude-code
depends_on:
- 01M4Z939HBTNVJ8F4X94C99WW9
position_column: todo
position_ordinal: '8780'
title: 'Gap G4: no test that an agent $/cancel_request of an elicitation/create removes the pending elicitation'
---
Found in T0. When Router ends an open question (a run cancel, `cancelAll`, close), ACPAgent ends its `elicitation/create` request with `$/cancel_request`. FoundationModelsACP cancels the handler task of the request, and `PendingRequestQueue` removes the item on that cancel.

`SessionModelPendingTests.cancellingTheAgentCallResolvesTheElicitationWithCancel` cancels the handler task directly. No test sends `$/cancel_request` over the connection.

Change (T2): a fixed-order test over a real in-memory connection: the stub agent sends a session-scoped `elicitation/create` with no prompt open, the test waits until `pendingElicitations` holds it (observation, no poll), the stub cancels its request task (the connection sends `$/cancel_request`), and the test waits until `pendingElicitations` is empty. A gate gives the order. #mail-step-6