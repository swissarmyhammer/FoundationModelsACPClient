---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
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

- [ ] A `session/new` that the agent answers with `-32000` sets `authState = .required(authMethods)`, and the call still throws the error.
- [ ] The same for `session/resume`, `session/list`, `session/close` and `session/delete`.
- [ ] A `-32000` answer when `authState` is `.authenticated` changes it to `.required`.
- [ ] Each other error does not change `authState`.
- [ ] A later successful `login(_:)` gives `.authenticated(methodId)`.
- [ ] The client span tests (`Tests/FoundationModelsACPClientTests/Telemetry/ModelRequestSpanTests.swift`) still pass.

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

- [ ] Write the six failing tests.
- [ ] Add `recordAuthRequired(ifThrownBy:)` and `sendRecordingAuth`.
- [ ] Use the helper in `ConnectionModel+Sessions.swift` and `ConnectionModel+List.swift`.
- [ ] Update the doc comment of `authState`.
