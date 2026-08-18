---
comments:
- actor: claude-code
  id: 01m0afnszw1r2tzarf215z26ge
  text: |-
    ### Research

    Discoveries about the wire package (FoundationModelsACP, ACP stable v2):

    - The `Client` protocol has two methods only: `sessionUpdate` and `requestPermission`. There is no other client method and no elicitation surface.
    - `RequestPermissionRequest` in this wire revision has `options: [PermissionOption]`, `sessionId`, `title`, `description?`, and `subject: RequestPermissionSubject?`. The card speaks of a `toolCall: ToolCallUpdate` field. That field is not in this wire revision. The `subject` field carries the tool-call context now, as `.toolCall(ToolCallPermissionSubject)` or `.command(CommandPermissionSubject)`. The pending state will hold the full `RequestPermissionRequest`, so the UI gets the options and the subject context.
    - `RequestPermissionOutcome` is `.cancelled` or `.selected(SelectedPermissionOutcome(optionId:))`.
    - `ClientCapabilities` in stable v2 has no field except `_meta`. The wire doc says: "stable v2 defines no standard client capability fields". So the client advertises an empty `ClientCapabilities()`, and that matches the implemented methods.
    - The connection supports `$/cancel_request`. When the agent withdraws the request, or the connection closes, the in-flight `requestPermission` handler Task gets a Swift task cancellation. So `withTaskCancellationHandler` covers agent withdrawal and transport close.
    - `AgentSideConnection.requestPermission` exists, so a stub agent can drive the full round trip over `InMemoryTransport.pair()`.

    ### Plan

    - New type `PendingPermissionRequest` (id + the wire request) in a new source file.
    - `ACPSessionState` gets `pendingPermissionRequests` (observable, ordered), `awaitPermissionDecision(for:)`, `answerPermissionRequest(_:with:)`, `cancelPermissionRequest(_:)`, and `cancelAllPermissionRequests()`. Continuations live in a private, observation-ignored dictionary. All paths run on the main actor, so no data race is possible.
    - Concurrency policy: more than one outstanding request is supported. Requests stay in arrival order and resolve independently. This gets documented.
    - `SwiftUIACPClient.requestPermission` suspends on the session state and resolves with the user's answer. A change to `.disconnected` cancels all pending requests in every session.
    - `ACPClient.advertisedCapabilities` states the empty capability set.
    - TDD: failing tests first in `Tests/FoundationModelsACPClientTests/PermissionRequestTests.swift`.
  timestamp: 2026-08-18T13:06:22.844449+00:00
- actor: claude-code
  id: 01m0anjaz9ynf3b258sj37j63m
  text: |-
    ### Implementation landed (TDD)

    RED: `Tests/FoundationModelsACPClientTests/PermissionRequestTests.swift` was written first, with 7 tests. The build failed because the new API did not exist. That failure was seen and recorded.

    GREEN: the implementation then landed in 4 source changes:

    - `Sources/FoundationModelsACPClient/PendingPermissionRequest.swift` (new): the observable pending value. It holds a local `UUID` identity plus the whole wire `RequestPermissionRequest`, so the UI gets the options and the subject context.
    - `Sources/FoundationModelsACPClient/ACPSessionState.swift`: `pendingPermissionRequests` (observable, arrival order), `awaitPermissionDecision(for:)`, `answerPermissionRequest(_:with:)`, `cancelPermissionRequest(_:)`, `cancelAllPermissionRequests()`. A private three-case enum (`awaitingRegistration` / `cancelledBeforeRegistration` / `suspended(continuation)`) makes each request's lifecycle state mutually exclusive, so every path resumes the continuation exactly one time and a resolved request keeps no state at all. Task cancellation (the connection's delivery of agent withdrawal and transport close) resolves with `cancelled` through a main-actor hop.
    - `Sources/FoundationModelsACPClient/SwiftUIACPClient.swift`: `requestPermission` now suspends on the session state and returns the user's decision. A change to `.disconnected` cancels all pending requests in every session.
    - `Sources/FoundationModelsACPClient/ACPClient.swift`: `advertisedCapabilities = ClientCapabilities()` — stable v2 gates no client method, so the empty set is exactly what is implemented.

    Concurrency policy, implemented and documented on `pendingPermissionRequests`: more than one outstanding request is supported; arrival order; independent resolution.

    ### What did not work / discoveries

    - The first full `swift test` run hung for 30+ minutes. Cause: the pre-existing placeholder test `requestPermissionAnswersCancelledUntilPendingStateLands` (SessionStateTests.swift) asserted the pre-M3 behavior — an immediate `cancelled` answer. With the new behavior, `requestPermission` suspends until the UI answers, and that test had no UI, so it waited without end. The test was deleted: this card replaces the placeholder behavior it tested, and the new PermissionRequestTests cover the whole surface. Note for the next agent: a hung `swift test` leaves `swiftpm-testing-helper` alive, and that blocks later builds on the SwiftPM lock — kill it before a re-run.
    - The test helper `waitUntil` now calls `Task.checkCancellation()` on each turn, so the Swift Testing time limit can stop a wait that does not end.
    - The card names a `toolCall: ToolCallUpdate` field on `RequestPermissionRequest`. The current wire revision carries `subject: RequestPermissionSubject?` instead (`.toolCall` / `.command`). The pending state holds the whole request, so the context lands either way.

    ### Verification

    - `rm -rf .build && swift build --build-tests`: 0 warnings, 0 errors.
    - `swift test` three times in a row: 39 tests, all pass, no failures, no skips.
  timestamp: 2026-08-18T14:49:20.617684+00:00
- actor: claude-code
  id: 01m0anjga6qhk5d7qec877004p
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPClient/PendingPermissionRequest.swift (new), Sources/FoundationModelsACPClient/ACPSessionState.swift, Sources/FoundationModelsACPClient/SwiftUIACPClient.swift, Sources/FoundationModelsACPClient/ACPClient.swift, Tests/FoundationModelsACPClientTests/PermissionRequestTests.swift (new, 7 tests), Tests/FoundationModelsACPClientTests/SessionStateTests.swift (superseded placeholder test removed). swift test: 39 tests pass, 0 failures, 0 warnings.
    - next: /review
  timestamp: 2026-08-18T14:49:26.086945+00:00
- actor: claude-code
  id: 01m0anm12e8hpdaaj4gr7dpkvp
  text: |-
    ### test — green
    - evidence: swift build (0 errors, 0 warnings); swift build --build-tests (0 errors, 0 warnings); swift test — 39 tests passed, 0 failed, 0 skipped
    - next: none. The build is clean.
  timestamp: 2026-08-18T14:50:16.014483+00:00
- actor: claude-code
  id: 01m0ann4spftdn9g24vh1tjh0c
  text: |-
    ### commit — changed
    - evidence: a1d9960 feat(session): add pending permission request as bindable state
    - next: none
  timestamp: 2026-08-18T14:50:52.598826+00:00
- actor: claude-code
  id: 01m0anvqyjc8rbne5xhbmk5mj4
  text: |-
    step: review
    outcome: clean
    evidence: review sha HEAD~1..HEAD — counts: findings 0, confirmed 0, refuted 2; 6 files reviewed, 4 files not reviewed (.kanban/ from .reviewignore)
    task: ^2z4mfsz
  timestamp: 2026-08-18T14:54:28.818162+00:00
- actor: claude-code
  id: 01m0anwa8esvyftc98y8py6wpe
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files (PendingPermissionRequest.swift new, ACPSessionState.swift, SwiftUIACPClient.swift, ACPClient.swift, PermissionRequestTests.swift new, SessionStateTests.swift)
    - test: green — swift test, 39 passed, 0 failures, 0 warnings
    - commit: a1d9960
    - review: clean — 0 findings on HEAD~1..HEAD; task moved to done
  timestamp: 2026-08-18T14:54:47.566325+00:00
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: done
position_ordinal: '8380'
title: 'M3 Pending requests as bindable state: permission now, elicitation later'
---
## What

`plan.md` -> **Pending requests are state, not callbacks**.

`requestPermission` (and later elicitation) is a *request the user must answer*. A callback cannot be rendered, so it must become **observable pending state** the UI binds to and resolves.

- Hold the pending request plus its continuation; complete it when the UI answers.
- Model `RequestPermissionRequest`'s `options: [PermissionOption]` and its `toolCall: ToolCallUpdate` context, so the UI can show *what* is being permitted.
- Handle **cancellation** (the agent gives up, the turn is cancelled, the connection drops) without leaking a continuation or leaving a ghost prompt on screen.
- Support more than one outstanding request, or explicitly document and enforce one-at-a-time.

Elicitation is the same shape and lands here once `FoundationModelsACP` ships the surface: **form mode** renders `requestedSchema` (flat primitives/enums); **URL mode** must display the target host and obtain consent before navigation, must never carry credentials back over ACP, and closes on `elicitation/complete`. Those are spec obligations. Advertise `clientCapabilities.elicitation` only for modes actually implemented -- requesting an unsupported mode is a `-32602`, and over-advertising causes exactly that.

## Acceptance Criteria

- [x] `requestPermission` sets observable pending state carrying options and tool-call context.
- [x] Answering from the UI resolves the agent's in-flight request with the chosen option.
- [x] Cancellation/disconnect clears pending state and leaks no continuation.
- [x] Concurrency policy (multiple vs. single outstanding) is implemented and documented.
- [x] Capabilities advertise only what is implemented.

## Tests

- [x] A stub agent's permission request appears as pending state; answering it resolves the agent's call with the selected option.
- [x] Cancelling the agent's request clears the prompt and leaves no suspended continuation (assert no leak).
- [x] Connection drop while pending clears state cleanly.
- [x] Two overlapping requests behave per the documented policy.
- [x] Advertised capabilities match implemented methods.

## Workflow

- Use `/tdd` -- write failing tests first.
