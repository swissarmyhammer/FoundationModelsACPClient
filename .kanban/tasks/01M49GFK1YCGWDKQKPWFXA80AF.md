---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4b8svv6642f73xvpg5mzbk1
  text: |-
    Research:
    - The ClientRequestSpan.send calls to wrap are now: newSession(_:) and replay(_:into:over:) and close(_:) in ConnectionModel+Sessions.swift; loadSessionPage(_:over:merge:) and deleteSession(_:) in ConnectionModel+List.swift. initialize, login and logout in ConnectionModel+Initialize.swift stay as they are.
    - ClientRequestSpan.send is `nonisolated(nonsending) static func send<Message: TracedClientMessage, Output>(_:parent:through:)` in Telemetry/TracedClientMessage.swift. No caller of ConnectionModel passes `parent`.
    - login/logout use a private `recordingFailure(of:_:)` that sets `.failed(AuthFailure)`. A successful login sets `.authenticated(methodId)`, so no change is necessary for the clear.
    - ScriptedStubAgent has no error option for session/new, session/list (it answers invalidParams only for a cursor with no page) or session/delete. The tests need `newSessionError`, `listSessionsError` and `deleteSessionError` options (default nil).
    - After initialize with auth methods, authState is already `.required`, so each per-method test must start from another state (a refused login gives `.failed`, a login gives `.authenticated`), else the test passes before the change.
  timestamp: 2026-10-07T13:28:17.510509+00:00
- actor: claude-code
  id: 01m4b94ct4bhyazhq9y4hnyksk
  text: |-
    Implementation landed (TDD).
    - RED: `swift test --filter ConnectionModelAuthRequiredTests` gave 7 failures at the `authState == .required` check. `anotherErrorKeepsTheAuthState` passed, because it guards behavior that already exists.
    - GREEN: I added ConnectionModel+AuthRequired.swift with `recordAuthRequired(ifThrownBy:)` and `sendRecordingAuth(_:through:)`. `sendRecordingAuth` wraps `ClientRequestSpan.send(_:parent:through:)`, so the span, the metrics and the trace `_meta` do not change. I put it at the five call sites: newSession, replay, close, loadSessionPage and deleteSession. initialize, login and logout do not use it.
    - I added two tests that the card does not list, because the acceptance criteria name session/close and session/delete: `aCloseThatNeedsAuthSetsRequired` and `aDeleteThatNeedsAuthSetsRequired`. The suite has 8 tests.
    - ScriptedStubAgent has three new options: `newSessionError`, `listSessionsError` and `deleteSessionError`. Each one defaults to nil, so no other test changes.
    - Docs: `ConnectionModel.authState` now says that `.required` also comes from a -32000 answer, after a login too. `AuthState` (the type doc and the `.required` doc) was wrong after this change, so I corrected it. The file headers of +Sessions and +List now name sendRecordingAuth.
  timestamp: 2026-10-07T13:34:02.564421+00:00
- actor: claude-code
  id: 01m4b94f9fd3ebfcf2zbczzw4f
  text: |-
    ### implement — changed
    - evidence: 7 files. New: Sources/FoundationModelsACPClient/Model/ConnectionModel+AuthRequired.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelAuthRequiredTests.swift. Changed: Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift, ConnectionModel+List.swift, ConnectionModel.swift, AuthState.swift, Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift. `swift test --filter ConnectionModelAuthRequiredTests`: 8/8 pass. `swift test`: 545 tests in 46 suites pass, 0 failures, ModelRequestSpanTests pass. The only warning is the accepted MLX "missing creator for mutated node" warning (zws9qzt).
    - next: /review. The task stays in doing. Not committed.
  timestamp: 2026-10-07T13:34:05.103624+00:00
position_column: doing
position_ordinal: '80'
title: 'Model: a -32000 answer to a ConnectionModel request sets authState to .required'
---
## What

ACP answers `-32000` (`ErrorCode.authenticationRequired`, `RequestError.authenticationRequired` in FoundationModelsACP `Connection/RequestError.swift:61`) when the agent needs a login before a request. Now the model does not record it: AgentViewKit finds it in the last `ErrorEntry` of a transcript, which is logic in the kit. The model must hold the fact.

This task covers the requests that `ConnectionModel` sends. Task "a -32000 answer to a session request" covers `prompt` and `setConfigOption` of `SessionModel`.

1. Add `Sources/FoundationModelsACPClient/Model/ConnectionModel+AuthRequired.swift`:
   - An internal `func recordAuthRequired(ifThrownBy error: any Error)`: when `error` is a `RequestError` with `code == .authenticationRequired`, set `authState = .required(authMethods)`. Each other error changes nothing.
   - An internal helper `func sendRecordingAuth<Message, Output>(_ message: Message, through send: ...) async throws -> Output` that calls `ClientRequestSpan.send(_:parent:through:)`, gives each thrown error to `recordAuthRequired(ifThrownBy:)`, and throws it again. Keep the span, the metrics and the trace `_meta` as they are now.
2. Use the helper at each `ClientRequestSpan.send` call of `ConnectionModel`, except `initialize` and `login`/`logout`:
   - `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift`: `newSession(_:)` (line 40), `replay(_:into:over:)` (line 149), `close(_:)` (line 271).
   - `Sources/FoundationModelsACPClient/Model/ConnectionModel+List.swift`: `loadSessionPage` (line 88), `deleteSession(_:)` (line 132).
3. A successful `login(_:)` already sets `.authenticated(methodId)`, so that clears the state. No other change is necessary for the clear.
4. Document on `ConnectionModel.authState` that `.required` also comes from a `-32000` answer, after a login too (for example an expired login).

## Acceptance Criteria

- [x] A `session/new` that the agent answers with `-32000` sets `authState = .required(authMethods)`, and the call still throws the error.
- [x] The same for `session/resume`, `session/list`, `session/close` and `session/delete`.
- [x] A `-32000` answer when `authState` is `.authenticated` changes it to `.required`.
- [x] Each other error does not change `authState`.
- [x] A later successful `login(_:)` gives `.authenticated(methodId)`.
- [x] The client span tests (`Tests/FoundationModelsACPClientTests/Telemetry/ModelRequestSpanTests.swift`) still pass.

## Tests

- Add `Tests/FoundationModelsACPClientTests/Model/ConnectionModelAuthRequiredTests.swift`. Use `ScriptedStubAgent` with its error options (for example `newSessionError: RequestError.authenticationRequired`) and `InitializeFixtures` with auth methods. No sleeps.
  - `aNewSessionThatNeedsAuthSetsRequired`
  - `aResumeThatNeedsAuthSetsRequired`
  - `aListThatNeedsAuthSetsRequired`
  - `anAuthenticatedConnectionGoesBackToRequired`
  - `anotherErrorKeepsTheAuthState`
  - `aLoginAfterRequiredGivesAuthenticated`
- Command: `swift test --filter ConnectionModelAuthRequiredTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [x] Write the six failing tests.
- [x] Add `recordAuthRequired(ifThrownBy:)` and `sendRecordingAuth`.
- [x] Use the helper in `ConnectionModel+Sessions.swift` and `ConnectionModel+List.swift`.
- [x] Update the doc comment of `authState`.
