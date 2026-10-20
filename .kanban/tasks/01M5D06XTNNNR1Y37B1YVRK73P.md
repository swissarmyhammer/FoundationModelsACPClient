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
- actor: claude-code
  id: 01m5d9t7srh0gk2b6nrvrj3w0k
  text: |-
    ### Research, 2026-10-20
    - The user approved the start of this card now.
    - `SessionModel.apply(_:)` is internal now. It sends the update to the update taps, then to the `ChunkCoalescer`, then to the engine. The preview factory uses `coalescingCadence: .zero`, thus the fold is synchronous. To make it public is sufficient for the first criterion.
    - `PreviewSessionRequestSender` conforms to the internal `SessionRequestSender`. It records nothing now.
    - Permission and elicitation answers resolve `PendingRequestQueue` (`resolve`, `cancel`, `cancelAll`, `complete(elicitationId:)`). Each of these goes through `PendingRequestQueue.resolve(_:with:)`. Plan: add a `didResolve` callback to the queue, and send the item and the response to the sender through a new main-actor requirement of `SessionRequestSender` with a no-op default. The live sender keeps the default.
    - `selectPermission` and `cancelPermission` wait on `permissionWrites` until the decision task signals. With no connection (`afterResponse == nil`) the wait ends one main-actor hop later. It is not for ever, but it is not "at once". Plan: the model keeps the ids of the pending permissions that have no connection, and the two calls do not wait for those ids.
    - Gap: the public preview factory can make pending permissions, but not pending elicitations. Thus only tests in this package (through internal `awaitElicitation`) can get an `.elicitationResponse` record. The agreed API does not add a public way. I will not change the `preview(...)` signature.
  timestamp: 2026-10-20T18:40:09.016555+00:00
- actor: claude-code
  id: 01m5db8q1a7s8jdz0peqdy106e
  text: |-
    ### Implementation landed, 2026-10-20
    - `SessionModel.apply(_:)` is now public. It is the same function that each wire update goes through: update taps, then `ChunkCoalescer`, then the engine. No second path.
    - `PreviewSessionRequestSender` is now `@MainActor @Observable`. `public private(set) var sent: [Sent]` holds each message in send order. `Sent` is `Hashable, Sendable`, with the agreed cases: `.prompt`, `.cancel`, `.setConfigOption`, `.permissionResponse(id:response:)`, `.elicitationResponse(id:response:)`. There is no `toolCallId` field.
    - New path for the answers: `PendingRequestQueue.didResolve` gets each item and response that `resolve`, `cancel` or `cancelAll` removes. `SessionModel` sends them to two new `@MainActor` requirements of `SessionRequestSender`, `didAnswerPermission(_:with:)` and `didAnswerElicitation(_:with:)`. A protocol extension gives a no-op default, so the live `ConnectionSessionRequestSender` and the test fakes do not change. A cancel of the task of the call (agent `$/cancel_request`) does not record an answer.
    - No wait on a preview: `awaitPermissionDecision` with no `afterResponse` puts the id in `permissionsWithNoConnection`. `selectPermission` and `cancelPermission` do not wait on `permissionWrites` for those ids, so Approve and Stop return before the decision task runs. The old code gave the signal one main-actor hop later.
    - What did not work: a first test expected two text chunks to join into one text block. The engine appends each chunk as its own block (see `SessionModelFoldTests.agentMessageChunksAppendToTheSameObject`). I corrected the expected value.
    - RED proof for the no-wait tests: with the new guard removed, `selectPermissionOnAPreviewModelReturnsAtOnce` did not return (the run timed out). With the guard, it passes.
    - README "Previews" section has a short example of `apply(_:)` and `sent`.
    - Open gap (not in scope, not changed): the public `preview(...)` factory makes no pending elicitation. Only tests in this package (through internal `awaitElicitation`) can make an `.elicitationResponse` record now.
  timestamp: 2026-10-20T19:05:31.946759+00:00
- actor: claude-code
  id: 01m5db90epkm9tjd7f5wssc2he
  text: |-
    ### implement — changed
    - evidence: `swift test` — 662 tests in 54 suites passed, 0 failures. 7 files: Sources/FoundationModelsACPClient/Model/SessionModel.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Pending.swift, Sources/FoundationModelsACPClient/Model/SessionRequestSender.swift, Sources/FoundationModelsACPClient/PendingRequestQueue.swift, Sources/FoundationModelsACPClient/Preview/PreviewSessionRequestSender.swift, README.md, and 2 new test files Tests/FoundationModelsACPClientTests/Preview/PreviewRecorderTests.swift and Tests/FoundationModelsACPClientTests/Preview/PreviewElicitationRecorderTests.swift. Not committed.
    - note: the build shows the SwiftPM line "warning: missing creator for mutated node" for the mlx-swift_Cmlx.bundle of a dependency. No source file of this change causes it.
    - next: /review. A follow-up card records the gap of a public pending elicitation on a preview model.
  timestamp: 2026-10-20T19:05:41.590391+00:00
- actor: claude-code
  id: 01m5dbjke8k0n1st1z39n2ktc7
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (f7ed2b0). 1 finding, 1 confirmed, 0 refuted. Tests/FoundationModelsACPClientTests/Preview/PreviewRecorderTests.swift:40 (reuse/reuse).
    - next: implement. Remove `RecorderFixtures.agentChunk(_:)` and use the shared `agentChunk(text:)` fixture. Then test, commit and review again.
  timestamp: 2026-10-20T19:10:55.944720+00:00
- actor: claude-code
  id: 01m5dbjyg5x7s81389p04t143j
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 8 files
    - test: green — swift test, 662 passed; IntegrationTests, 1 passed
    - commit: f7ed2b0
    - review: findings — Tests/FoundationModelsACPClientTests/Preview/PreviewRecorderTests.swift:40
  timestamp: 2026-10-20T19:11:07.269556+00:00
- actor: claude-code
  id: 01m5dbp60ejawpfkxvne8h7dc9
  text: |-
    ### Review finding fixed, 2026-10-20
    - Finding `PreviewRecorderTests.swift:40` `reuse/reuse`: I deleted `RecorderFixtures.agentChunk(_:)` and `RecorderFixtures.agentMessageId`. Nothing else read `agentMessageId`. The three call sites now use the shared `agentChunk(text:)`. There is no wrapper with the same name.
    - Same cause in the same file, also removed: `promptContent` and the expected value of `twoAppliedChunksFoldAtOnceIntoOneAgentMessage` now use the shared `textBlock(_:)`, not `.text(TextContent(text:))`. The local `RecorderFixtures.allowOption` copied `SessionModelFixtures.allowOption`. I deleted it. The tests now use `SessionModelFixtures.allowOption`. The permission request keeps `SessionModel.previewSessionId`, because the shared `SessionModelFixtures.permissionRequest()` uses `testSession` and two options. That is a different request.
    - The file still has no `@testable import`. The shared fixtures are internal symbols of the test module, so the file can use them.
    - `PreviewElicitationRecorderTests.swift` does not have the same duplication. Its `startElicitation(on:)` starts the call with `Task.immediate` and does not wait. No shared fixture does this. I did not change the file.
    - The rule dump (`dump validators`) was 754 KB, too large to read whole. The finding gives the `reuse` rule word for word, and I used it.
  timestamp: 2026-10-20T19:12:53.262330+00:00
- actor: claude-code
  id: 01m5dbp89bbj3br7cpmkjk323k
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPClientTests/Preview/PreviewRecorderTests.swift. `swift test`: 662 tests in 54 suites passed, 0 failures. The SwiftPM line "warning: missing creator for mutated node" for the mlx-swift_Cmlx.bundle of a dependency shows again. It showed before this change, and no source file causes it. Finding PreviewRecorderTests.swift:40 is now `- [x]`. Not committed.
    - next: /test, then /commit, then /review.
  timestamp: 2026-10-20T19:12:55.595091+00:00
- actor: claude-code
  id: 01m5dbrqehwd07savy5rfbyz43
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 963fc3b). 1 file reviewed. 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. The prior finding at `PreviewRecorderTests.swift:40` (`reuse/reuse`) is checked.
    - next: none. The task moved to done.
  timestamp: 2026-10-20T19:14:16.657053+00:00
- actor: claude-code
  id: 01m5dbrz75xtgbynn3v7qen6r0
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file (PreviewRecorderTests.swift)
    - test: green — swift test, 662 passed
    - commit: 963fc3b
    - review: clean — 0 findings; the prior finding is checked
  timestamp: 2026-10-20T19:14:24.613229+00:00
position_column: done
position_ordinal: ff9580
title: 'AVK-7 (Step 5): public SessionModel.apply(_:) and a recorder of outgoing requests'
---
Source: decision D105 (h) in ../TestudoApp/features/decisions.md. The request came from the testudoapp-4c session on 2026-10-20. Do not start it now. It is Step 5 work.

Agree on the API with the agentviewkit-98 session when it plans AVK-7. `BoardModel` (KanbanViewKit) and `TimelineModel` (SnapshotViewKit) get the same parts, so keep the shapes the same.

## Scope
- A public `SessionModel.apply(_:)`. It takes one `SessionUpdate` with no wire, so code can build and change a session model for previews and tests. It adds to the existing `SessionModel.preview(...)`.
- A recorder of the outgoing requests of a code-built model. A test reads it to check that Send sends `session/prompt` with the correct content. Start from `Preview/PreviewSessionRequestSender.swift`: it already gets each prompt request through `willSend`.

## Acceptance criteria
- [x] `apply(_:)` uses the same merge path as a wire update, so a preview model and a live model show the same transcript.
- [x] A test builds a model, applies updates, sends a prompt, and reads the recorded `session/prompt` request.
- [x] The API is agreed with agentviewkit-98 before the implementation. #step-5

## Review Findings (2026-10-20 14:09)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Tests/FoundationModelsACPClientTests/Preview/PreviewRecorderTests.swift:40` `reuse/reuse` — The new static function `RecorderFixtures.agentChunk(_:)` reimplements the shared test fixture `agentChunk(text:message:)`. The shared fixture has the same shape, the same default message id ("agent-1"), and builds the same `.agentMessageChunk` update with a text block. Two copies of this helper can drift apart. The local copy also adds a second, unlabeled `agentChunk(_:)` name for the same capability. Delete `RecorderFixtures.agentChunk(_:)` and the `agentMessageId` constant if nothing else reads it. Call the shared `agentChunk(text:)` at each site instead, for example `model.apply(agentChunk(text: "Hello, "))`. The shared fixture gives the same message id by default, so the tests keep their meaning. Do not keep a static wrapper with the same name, because inside the wrapper an unqualified call would resolve to the wrapper itself.
