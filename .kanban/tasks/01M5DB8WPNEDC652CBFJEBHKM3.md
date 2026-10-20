---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Preview: a public way to make a pending elicitation on a preview SessionModel'
---
Found during ^yvrk73p (AVK-7).

`PreviewSessionRequestSender.sent` can record `.elicitationResponse(id:response:)`, but `SessionModel.preview(...)` makes only pending permissions. A host app or AgentViewKit test cannot make a pending elicitation on a preview model, so it cannot get this record. Only tests in this package can, through the internal `awaitElicitation`.

Agree the API with agentviewkit-98 before the work. One possible shape: a `pendingElicitations: [CreateElicitationRequest]` parameter on `preview(...)`, as `pendingPermissions` has. That changes the public signature, so the decision is necessary first.

## Acceptance criteria
- [ ] The API is agreed with agentviewkit-98.
- [ ] A test of the public API makes a preview model with a pending elicitation, answers it, and reads the `.elicitationResponse` record. #step-5