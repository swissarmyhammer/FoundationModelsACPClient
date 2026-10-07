---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4bev6gd9s5dq6ymgewdcgt5
  text: |-
    Research:
    - `ConnectionSessionRequestSender` holds only `connection`; task 3p0m0c1 did not change it. `prompt` and `setConfigOption` go through `ClientRequestSpan.send`.
    - `makeSubscribedSessionModel(sessionId:over:)` in `ConnectionModel+Sessions.swift` makes the sender; it has the connection as a parameter, so the closure can compare it with `ConnectionModel.connection`.
    - `connect(over:...)` does not close the earlier connection, so a session of the earlier connection can still send. The test for item 4 uses this: connect the same model a second time with a new `ConnectedModel(model:)`.
    - `ScriptedStubAgent` has `promptError`, but no error for `session/set_config_option`. The test needs a new `setConfigOptionError` parameter on the stub (test code only).
    - A callback closure that branches must call a named method (swift initialization rule), so the connection check goes in a named method in `ConnectionModel+AuthRequired.swift`.
  timestamp: 2026-10-07T15:13:52.653695+00:00
- actor: claude-code
  id: 01m4bf3v6kmwf85mpxzq5nq5e5
  text: |-
    Implementation notes:
    - TDD order: the four tests first. RED: `aPromptThatNeedsAuthSetsRequired` and `aConfigChangeThatNeedsAuthSetsRequired` failed on `authState`. The other two passed, because nothing recorded yet. Then I added `requestDidFail` and a closure with no connection check. `aSessionOfAnEarlierConnectionDoesNotChangeTheAuthState` then failed (state became `.required`), which proves the test catches a missing check. Then I added the check, and all 12 tests passed.
    - `ConnectionSessionRequestSender`: new `requestDidFail`. `prompt` and `setConfigOption` go through a private `reportingFailure` helper that gives each error to `requestDidFail`, then throws it again. `cancel` did not change.
    - The connection check is a named method `ConnectionModel.recordAuthRequired(ifThrownBy:over:)` in `ConnectionModel+AuthRequired.swift`, because a callback closure that branches must call a named method (swift initialization rule). The closure in `makeSubscribedSessionModel` holds `self` weakly and calls that method.
    - Test support: `ScriptedStubAgent` has a new `setConfigOptionError`. The fixture `connect` takes `model:` (to connect one model two times), `promptError:`, and `setConfigOptionError:`.
    - The earlier-connection test connects the same model a second time without a disconnect. `connect(over:)` does not close the earlier connection, so the session of the earlier connection can still send a prompt. The test asserts that the earlier agent got the prompt.
    - Doc comments updated: `ConnectionModel.authState`, `AuthState`, and the file header of `ConnectionModel+AuthRequired.swift`.
    - No code in this package reads the `ErrorEntry` for auth. The "kit" in item 3 is a consumer outside this package. The prompt test asserts that the `ErrorEntry` and the `.failed` state stay.
  timestamp: 2026-10-07T15:18:35.987763+00:00
- actor: claude-code
  id: 01m4bf3xxxjd8kx2jhfcszcpmh
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACPClient/Model/ConnectionSessionRequestSender.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+AuthRequired.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Sources/FoundationModelsACPClient/Model/AuthState.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelAuthRequiredTests.swift, Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift. `swift test --filter ConnectionModelAuthRequiredTests`: 12 passed. `swift test`: 559 tests in 48 suites passed, 0 failures. The only warning is the accepted MLX "missing creator for mutated node" (task zws9qzt).
    - next: /review. The task stays in doing. Nothing is committed.
  timestamp: 2026-10-07T15:18:38.781033+00:00
depends_on:
- 01M49GFK1YCGWDKQKPWFXA80AF
position_column: doing
position_ordinal: '80'
title: 'Model: a -32000 answer to a session prompt or config request sets authState to .required'
---
## What

Task ^fxa80af records a `-32000` answer (`ErrorCode.authenticationRequired`) to the requests of `ConnectionModel`. The requests of a session go another way: `SessionModel.prompt(_:meta:)` and `setConfigOption(_:)` send through `ConnectionSessionRequestSender` (`Sources/FoundationModelsACPClient/Model/ConnectionSessionRequestSender.swift`), which holds only the connection. The most frequent `-32000` (a prompt after the login expired) thus does not reach `ConnectionModel.authState`. Now the kit reads it from the `ErrorEntry` of the transcript.

1. In `ConnectionSessionRequestSender.swift`, add a stored property `let requestDidFail: @MainActor @Sendable (any Error) -> Void`. In `prompt(_:willSend:)` and `setConfigOption(_:)`, call it with each thrown error, then throw the error again. `cancel(_:)` is a notification and gets no answer; do not change it.
2. In `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift`, `makeSubscribedSessionModel(sessionId:over:)` (line 216): give the sender `requestDidFail: { [weak self] error in self?.recordAuthRequired(ifThrownBy: error) }`. The closure holds the model weakly, so a session model does not keep its connection model alive.
3. `SessionModel.prompt(_:meta:)` keeps its `ErrorEntry` in the transcript, as now. The kit stops to read it for the auth state.
4. A `-32000` from a session whose connection is no longer the open connection of the model must not change `authState`: in `recordAuthRequired` or in the closure, compare the connection of the sender with `ConnectionModel.connection`.

## Acceptance Criteria

- [x] A `session/prompt` that the agent answers with `-32000` sets `ConnectionModel.authState = .required(authMethods)`. The prompt entry still gets `.failed`, and the transcript still gets the `ErrorEntry`.
- [x] A `session/set_config_option` with a `-32000` answer does the same.
- [x] A prompt that fails with another error does not change `authState`.
- [x] A `-32000` on a session of an earlier connection does not change the state of the new connection.
- [x] `FakeSessionRequestSender` tests (`Tests/FoundationModelsACPClientTests/Model/FakeSessionRequestSender.swift`) need no change.

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

- [x] Write the four failing tests.
- [x] Add `requestDidFail` to `ConnectionSessionRequestSender`, and call it in `prompt` and `setConfigOption`.
- [x] Give the closure in `makeSubscribedSessionModel(sessionId:over:)`, with the connection check.
