---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5dham389ghbjqabptgb0cwv
  text: |-
    ### API proposal to agentviewkit-98, 2026-10-20. Waits for their answer.
    - Add `pendingElicitations: [CreateElicitationRequest] = []` to `SessionModel.preview(...)`, after `pendingPermissions`. Each request becomes a `PendingElicitation` in `pendingElicitations` and in the FIFO `pendingRequests`, in the given order, after the permissions.
    - The default is empty, so existing call sites do not change.
    - Accept or decline records `.elicitationResponse(id: <PendingElicitation.ID>, response:)` in `PreviewSessionRequestSender.sent` and returns at once.
    - Question to them: session scope only, or also a request-scoped elicitation on `ConnectionModel.preview(...)`?
  timestamp: 2026-10-20T20:51:25.928197+00:00
- actor: claude-code
  id: 01m5dhcwvrgabr7deptb503xn1
  text: |-
    ### Research
    - `SessionModel.preview(...)` starts each pending permission with `startPermissionDecision(for:)` (a `Task.immediate` on the main actor). An elicitation needs the same shape: a new internal `startElicitation(for:)` that calls `awaitElicitation(_:)`. The shared arrival space of the model puts the elicitations after the permissions in `pendingRequests`.
    - The session queue `didResolve` already calls `requestSender.didAnswerElicitation`, so `PreviewSessionRequestSender.sent` gets `.elicitationResponse` with no other change. The session elicitation calls do not wait for a write, so they return at once.
    - `ConnectionModel.elicitations` has no `didResolve`. `awaitRequestScopedElicitation` needs an open connection (`inFlightMethod`), so the preview must call `elicitations.awaitResponse(to:)` directly, with `requestMethod: nil` (no in-flight request in a preview).
    - Recorder decision for the connection: add one parameter `recorder: PreviewSessionRequestSender = PreviewSessionRequestSender()` to `ConnectionModel.preview(...)`. The preview sets `elicitations.didResolve` to `recorder.didAnswerElicitation`. This adds no new public type and reuses `Sent.elicitationResponse(id:response:)`.
    - Test fixtures to reuse: `ElicitationFixtures.formRequest(scope:)` and `ElicitationFixtures.requestScope` in `Tests/FoundationModelsACPClientTests/ElicitationFixtures.swift`.
  timestamp: 2026-10-20T20:52:40.440018+00:00
- actor: claude-code
  id: 01m5dhk54qx9ry3z30bpy25bba
  text: |-
    ### Implementation landed
    - Session scope: `SessionModel.preview(...)` has `pendingElicitations: [CreateElicitationRequest] = []` after `pendingPermissions`. A new internal `SessionModel.startElicitation(for:)` (beside `startPermissionDecision(for:)`) starts each one. The shared arrival space puts them after the permissions in `pendingRequests`. The existing `didResolve` hook records `.elicitationResponse` in `requestSender.sent`.
    - Request scope: `ConnectionModel.preview(...)` has two new parameters at the end: `pendingElicitations: [CreateElicitationRequest] = []` and `recorder: PreviewSessionRequestSender = PreviewSessionRequestSender()`. This is the smallest public addition: no new public type, the same `Sent.elicitationResponse(id:response:)` shape. The preview sets `elicitations.didResolve` to `recorder.didAnswerElicitation`. A new internal `ConnectionModel.startRequestScopedElicitation(for:)` starts each one with `requestMethod == nil`, because no client request is in flight in a preview.
    - Docs: the DocC links to the old `SessionModel.preview` signature are updated. `PreviewSessionRequestSender` and `Sent.elicitationResponse` say that the connection preview uses the same recorder. README "Previews" has a paragraph and an example.
    - Tests (public API, no `@testable`), in `PreviewRecorderTests`: FIFO order after a permission, a decline recorded on a session; a request-scoped item in `connection.pendingElicitations`, a decline recorded in the connection recorder. They reuse `ElicitationFixtures.formRequest(scope:)` and `ElicitationFixtures.requestScope`.
    - `PreviewElicitationRecorderTests` (the `@testable` file) had a header that said the public factory makes no pending elicitation. That is false now, so the header is updated, and its private helper calls the new `startElicitation(for:)` and no longer copies the `Task.immediate` body.
    - RED: the build failed with "extra argument 'pendingElicitations' in call". GREEN: the 16 preview recorder tests passed.
    - The SwiftPM line "warning: missing creator for mutated node" (mlx-swift_Cmlx.bundle of a dependency) shows in the root package and in `IntegrationTests`. No file of this change causes it. The new card ^kc2d71h records it.
  timestamp: 2026-10-20T20:56:05.527193+00:00
- actor: claude-code
  id: 01m5dhk8pgac5c0asxc121kv7e
  text: |-
    ### implement — changed
    - evidence: `swift test` — 666 tests in 54 suites passed, 0 failures. `swift build --build-tests` in IntegrationTests — 0 errors. 9 files: Sources/FoundationModelsACPClient/Preview/SessionModel+Preview.swift, Sources/FoundationModelsACPClient/Preview/ConnectionModel+Preview.swift, Sources/FoundationModelsACPClient/Preview/PreviewSessionRequestSender.swift, Sources/FoundationModelsACPClient/Preview/PreviewTranscriptItem.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Elicitation.swift, Tests/FoundationModelsACPClientTests/Preview/PreviewRecorderTests.swift, Tests/FoundationModelsACPClientTests/Preview/PreviewElicitationRecorderTests.swift, README.md. Not committed.
    - note: the pre-existing SwiftPM line "warning: missing creator for mutated node" (dependency MLX bundle) is recorded on ^kc2d71h.
    - next: /review.
  timestamp: 2026-10-20T20:56:09.168573+00:00
position_column: doing
position_ordinal: '80'
title: 'Preview: a public way to make a pending elicitation on a preview SessionModel'
---
Found during ^yvrk73p (AVK-7).

`PreviewSessionRequestSender.sent` can record `.elicitationResponse(id:response:)`, but `SessionModel.preview(...)` makes only pending permissions. A host app or AgentViewKit test cannot make a pending elicitation on a preview model, so it cannot get this record. Only tests in this package can, through the internal `awaitElicitation`.

## Agreed API (agentviewkit-98, 2026-10-20)
- Session scope: add `pendingElicitations: [CreateElicitationRequest] = []` to `SessionModel.preview(...)`, after `pendingPermissions`. Each request becomes a `PendingElicitation` in `pendingElicitations` and in the FIFO `pendingRequests`, in the given order, after the permissions. Accept, decline or cancel records `.elicitationResponse(id: <PendingElicitation.ID>, response:)` in the recorder of the preview, and returns at once.
- Request scope: the same shape on `ConnectionModel.preview(...)`: a parameter `pendingElicitations: [CreateElicitationRequest] = []`. Each request becomes a request-scoped `PendingElicitation` in `connection.pendingElicitations`. An answer is recorded in a recorder that a test of the public API can read (the same `Sent.elicitationResponse(id:response:)` shape), and returns at once.
- AgentViewKit reads `connection.pendingElicitations` in `RequestDeck(connection:)` and in `ThreadAccessibility.swift`, which joins `session.pendingElicitations` and `connection?.pendingElicitations`.
- The defaults are empty, so existing call sites do not change.

## Acceptance criteria
- [x] The API is agreed with agentviewkit-98.
- [x] A test of the public API makes a preview session model with a pending elicitation, answers it, and reads the `.elicitationResponse` record.
- [x] A test of the public API makes a preview connection model with a pending request-scoped elicitation, answers it, and reads the `.elicitationResponse` record. #step-5