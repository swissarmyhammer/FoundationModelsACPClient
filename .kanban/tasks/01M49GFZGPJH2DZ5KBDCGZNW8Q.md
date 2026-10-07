---
assignees:
- claude-code
depends_on:
- 01M49GFK1YCGWDKQKPWFXA80AF
position_column: todo
position_ordinal: '8880'
title: 'Model: a -32000 answer to a session prompt or config request sets authState to .required'
---
## What

Task ^fxa80af records a `-32000` answer (`ErrorCode.authenticationRequired`) to the requests of `ConnectionModel`. The requests of a session go another way: `SessionModel.prompt(_:meta:)` and `setConfigOption(_:)` send through `ConnectionSessionRequestSender` (`Sources/FoundationModelsACPClient/Model/ConnectionSessionRequestSender.swift`), which holds only the connection. The most frequent `-32000` (a prompt after the login expired) thus does not reach `ConnectionModel.authState`. Now the kit reads it from the `ErrorEntry` of the transcript.

1. In `ConnectionSessionRequestSender.swift`, add a stored property `let requestDidFail: @MainActor @Sendable (any Error) -> Void`. In `prompt(_:willSend:)` and `setConfigOption(_:)`, call it with each thrown error, then throw the error again. `cancel(_:)` is a notification and gets no answer; do not change it.
2. In `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift`, `makeSubscribedSessionModel(sessionId:over:)` (line 216): give the sender `requestDidFail: { [weak self] error in self?.recordAuthRequired(ifThrownBy: error) }`. The closure holds the model weakly, so a session model does not keep its connection model alive.
3. `SessionModel.prompt(_:meta:)` keeps its `ErrorEntry` in the transcript, as now. The kit stops to read it for the auth state.
4. A `-32000` from a session whose connection is no longer the open connection of the model must not change `authState`: in `recordAuthRequired` or in the closure, compare the connection of the sender with `ConnectionModel.connection`.

## Acceptance Criteria

- [ ] A `session/prompt` that the agent answers with `-32000` sets `ConnectionModel.authState = .required(authMethods)`. The prompt entry still gets `.failed`, and the transcript still gets the `ErrorEntry`.
- [ ] A `session/set_config_option` with a `-32000` answer does the same.
- [ ] A prompt that fails with another error does not change `authState`.
- [ ] A `-32000` on a session of an earlier connection does not change the state of the new connection.
- [ ] `FakeSessionRequestSender` tests (`Tests/FoundationModelsACPClientTests/Model/FakeSessionRequestSender.swift`) need no change.

## Tests

- Add tests to `Tests/FoundationModelsACPClientTests/Model/ConnectionModelAuthRequiredTests.swift` (made by task ^fxa80af), with `ScriptedStubAgent` and a prompt error of `RequestError.authenticationRequired`. No sleeps.
  - `aPromptThatNeedsAuthSetsRequired`
  - `aConfigChangeThatNeedsAuthSetsRequired`
  - `aPromptWithAnotherErrorKeepsTheAuthState`
  - `aSessionOfAnEarlierConnectionDoesNotChangeTheAuthState`
- Command: `swift test --filter ConnectionModelAuthRequiredTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [ ] Write the four failing tests.
- [ ] Add `requestDidFail` to `ConnectionSessionRequestSender`, and call it in `prompt` and `setConfigOption`.
- [ ] Give the closure in `makeSubscribedSessionModel(sessionId:over:)`, with the connection check.
