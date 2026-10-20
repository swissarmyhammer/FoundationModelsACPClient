---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5d09j96jcaks92e7b4r90q6
  text: |-
    ### API proposal to agentviewkit-98 (their card ^y1e9rmy), 2026-10-20. Waits for their answer.
    - `public func apply(_ update: SessionUpdate)`: the same path as the wire. A preview model has a `.zero` cadence, so the fold is synchronous.
    - `PreviewSessionRequestSender` becomes `@MainActor @Observable`, with `public private(set) var sent: [Sent]` in send order. The cases of `Sent`: `.prompt`, `.cancel`, `.setConfigOption`, `.permissionResponse`, `.elicitationResponse`.
    - Permission and elicitation answers do not go through `SessionRequestSender` today. Add a path for them to the recorder. Also make sure that `selectPermission` and `cancelPermission` do not wait on `permissionWrites` for ever on a preview model, which has no connection.
  timestamp: 2026-10-20T15:53:45.510781+00:00
- actor: claude-code
  id: 01m5d09w8sqzzjde264yqe39nq
  text: |-
    ### API agreed with agentviewkit-98 (^y1e9rmy), 2026-10-20
    The API of the first comment is agreed, with this decision for the identity field:
    - `.permissionResponse(id: PendingPermissionRequest.ID, response: RequestPermissionResponse)`
    - `.elicitationResponse(id: <the local pending id of the elicitation>, response: <the elicitation response>)`
    The local id is necessary. AgentViewKit names a request by this id (payload key `request` = `uuidString`, scope `agentRequest:<uuid>`), and a permission request does not always have a tool call. Do not add a `toolCallId` field. A test reads the tool call from the pending request.
  timestamp: 2026-10-20T15:53:55.737344+00:00
position_column: todo
position_ordinal: '80'
title: 'AVK-7 (Step 5): public SessionModel.apply(_:) and a recorder of outgoing requests'
---
Source: decision D105 (h) in ../TestudoApp/features/decisions.md. The request came from the testudoapp-4c session on 2026-10-20. Do not start it now. It is Step 5 work.

Agree on the API with the agentviewkit-98 session when it plans AVK-7. `BoardModel` (KanbanViewKit) and `TimelineModel` (SnapshotViewKit) get the same parts, so keep the shapes the same.

## Scope
- A public `SessionModel.apply(_:)`. It takes one `SessionUpdate` with no wire, so code can build and change a session model for previews and tests. It adds to the existing `SessionModel.preview(...)`.
- A recorder of the outgoing requests of a code-built model. A test reads it to check that Send sends `session/prompt` with the correct content. Start from `Preview/PreviewSessionRequestSender.swift`: it already gets each prompt request through `willSend`.

## Acceptance criteria
- [ ] `apply(_:)` uses the same merge path as a wire update, so a preview model and a live model show the same transcript.
- [ ] A test builds a model, applies updates, sends a prompt, and reads the recorded `session/prompt` request.
- [ ] The API is agreed with agentviewkit-98 before the implementation. #step-5