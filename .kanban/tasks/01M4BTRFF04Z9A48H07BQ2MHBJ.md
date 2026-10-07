---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4bvh1f9d99jrpks7c3kexbr
  text: |-
    Research:
    - No exhaustive `switch` over `AuthFailure.Reason` exists in Sources, Tests, IntegrationTests or the acp-client executable. The `case .terminal(` in `ProbeReport.swift` is a switch over `AuthMethod`, not over `AuthFailure.Reason`. The new `Reason.message` is the first switch.
    - `RequestError` is a typealias of `ACPError`, which has a public `message: String`.
    - Existing tests that expect no state change for an unsupported call: `ConnectionModelInitializeTests.aLogoutWithNoCapabilityKeepsTheAuthState`, the helper `expectRefusedLogin(of:by:)` (used by `loginWithATerminalMethodThrowsAndSendsNothing` and `loginWithAnUnlistedMethodThrowsAndSendsNothing`), and `ConnectionModelTerminalAuthTests.noTerminalCapabilityDoesNotCallTheRunner` and `anAgentMethodIdIsNotRunInATerminal`.
    - `aLogoutWithNoCapabilityThrowsUnsupportedAndSendsNothing` checks `.notRequired` after a second `initialize`. That `initialize` resets the state, so the check stays true.
  timestamp: 2026-10-07T18:55:31.305705+00:00
- actor: claude-code
  id: 01m4bw32s5n1nekwxjwzfjsmqk
  text: |-
    Implementation:
    - RED 1: `swift test --filter ConnectionModel` did not compile: "type 'AuthFailure.Reason' has no member 'unsupported'".
    - GREEN 1: added `AuthFailure.Reason.unsupported(method:)` and the public `Reason.message`. The 3 message tests passed. The 7 state expectations failed at run time (RED 2), as expected.
    - GREEN 2: added the internal `ConnectionModel.recordUnsupported(of:method:) -> ConnectionModelError` in `ConnectionModel+Initialize.swift`. It sets `authState` to `.failed(AuthFailure(operation:reason: .unsupported(method:)))` and gives the error to throw. `login(_:)` and `logout(_:)` now use `guard … else { throw recordUnsupported(…) }` in place of `requireCapability(_:method:)`. `runnableTerminalMethod(_:)` uses it too. `requireCapability(_:method:)` stays: list, delete, resume, close and additionalDirectories use it.
    - The order did not change: the unsupported check is before `openConnection()`. Thus a call with no open connection, when the agent lists the method, still throws `ConnectionError.closed` and changes no state (out of scope, `aLoginWithNoOpenConnectionKeepsTheAuthState` still passes).
    - Message texts: unsupported gives "The agent cannot do this authentication operation."; a terminal failure with no message gives "The sign-in process stopped with exit status N." or "The sign-in process did not stop normally.".
    - Test changes: new `anUnsupportedLoginRecordsTheFailure` (agent lists no auth method), `anUnsupportedLogoutRecordsTheFailure` (it replaces `aLogoutWithNoCapabilityKeepsTheAuthState`), `eachReasonHasAMessage` (6 arguments), `aRequestReasonGivesTheMessageOfTheError`, `aTerminalReasonWithAMessageGivesThatMessage`, `anUnsupportedTerminalLoginRecordsTheFailure` (unlisted id). Updated `expectRefusedLogin(of:by:)`, `noTerminalCapabilityDoesNotCallTheRunner` and `anAgentMethodIdIsNotRunInATerminal` to expect the recorded failure.
    - I did not do the last subtask ("Tell agentviewkit-a3 the commit"). The orchestrator does it.
  timestamp: 2026-10-07T19:05:22.469026+00:00
- actor: claude-code
  id: 01m4bw379za0kq1f2fezfcbg2z
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPClient/Model/AuthFailure.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+TerminalAuth.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelTerminalAuthTests.swift. `swift build` exit 0. `swift test --filter ConnectionModel`: 143 tests in 7 suites passed. `swift test`: 577 tests in 49 suites passed, 0 failures. `swift build --package-path IntegrationTests --build-tests` exit 0. The only warning is the accepted MLX warning "missing creator for mutated node".
    - next: /review. The task stays in doing. The commit must use a `!` conventional commit with a `BREAKING CHANGE:` footer. The last subtask (tell agentviewkit-a3 the commit) is for the orchestrator.
  timestamp: 2026-10-07T19:05:27.103436+00:00
- actor: claude-code
  id: 01m4bw756fw30fq59aj8zf7bz2
  text: |-
    ### test — green
    - evidence: swift build: complete, 0 warnings in package code. swift test: 577 tests in 49 suites passed, 0 failed, 0 skipped. swift build --package-path IntegrationTests --build-tests: complete.
    - note: the only warning is "missing creator for mutated node" from the MLX bundle. It is accepted. No warnings from .build/checkouts were seen.
    - next: review
  timestamp: 2026-10-07T19:07:36.015605+00:00
position_column: doing
position_ordinal: '80'
title: 'Model: record an unsupported login, logout or terminal login in authState'
---
## What

Request from AgentViewKit (session agentviewkit-a3), at client pin 36f3249. AgentViewKit binds its sign-in views only to `ConnectionModel.authState` and keeps no error state of its own. Thus it cannot show a call that the model refuses.

Now these three calls throw `ConnectionModelError.unsupported(method:)` and do not change `authState`:

- `login(_:)`: `requireCapability(canLogin(with:), …)` at `Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift:205`.
- `logout(_:)`: `requireCapability(canLogout, …)` at `ConnectionModel+Initialize.swift:227`.
- `loginWithTerminal(_:runner:)`: `runnableTerminalMethod(_:)` at `Sources/FoundationModelsACPClient/Model/ConnectionModel+TerminalAuth.swift:113`.

Also, the error has no text that a view can show.

Change:

1. Add `case unsupported(method: String)` to `AuthFailure.Reason` (`Sources/FoundationModelsACPClient/Model/AuthFailure.swift:22`). `method` is the same value that `ConnectionModelError.unsupported(method:)` holds: the ACP wire method, or `ConnectionModelError.terminalAuthOperation` for a terminal login.
2. Add a public computed property `AuthFailure.Reason.message: String`, a text that a view can show, for each reason:
   - `.request(let error)`: the message of the `RequestError`.
   - `.terminal(let exitStatus, let message)`: the message when there is one. If not, a text that gives the exit status, or that says the process did not exit normally.
   - `.unsupported`: a text that says that the agent does not support this auth operation. Use STE wording.
3. In `login(_:)`, `logout(_:)` and `loginWithTerminal(_:runner:)`: when the call is unsupported, set `authState` to `.failed(AuthFailure(operation:reason: .unsupported(method:)))` with the operation of the call (`.login(id)`, `.logout`, `.terminalLogin(id)`), then throw the same `ConnectionModelError.unsupported(method:)` as now. The call still sends nothing.
4. Update the doc comments of the three calls. They now say that the call "changes no state" when it is unsupported, and that is no longer true. Also update the doc comment of `AuthFailure.Reason`.

Out of scope: a call made when no connection is open still throws `ConnectionError.closed` and does not change `authState`. Do not change this here.

Adding an enum case to the public `AuthFailure.Reason` is a breaking change for a `switch` with no `default` in a host. Use a `!` conventional commit with a `BREAKING CHANGE:` footer.

## Acceptance Criteria

- [x] An unsupported `login(_:)` (a `terminal` method id, or an id that the agent does not list) sets `authState` to `.failed` with operation `.login(id)` and reason `.unsupported(method: "auth/login")` (the wire method constant), and still throws `ConnectionModelError.unsupported`.
- [x] An unsupported `logout(_:)` (`canLogout == false`) sets `authState` to `.failed` with operation `.logout` and reason `.unsupported`, and still throws.
- [x] An unsupported `loginWithTerminal(_:runner:)` sets `authState` to `.failed` with operation `.terminalLogin(id)` and reason `.unsupported(method: ConnectionModelError.terminalAuthOperation)`, does not call the runner, and still throws.
- [x] `AuthFailure.Reason.message` gives a text that is not empty for each case.
- [x] Each existing test passes. `swift build`, `swift test`, and `swift build --package-path IntegrationTests` pass, with no new warning.

## Tests

- In the existing auth test files under `Tests/FoundationModelsACPClientTests/Model/`, for example the files that test `login`, `logout` and `loginWithTerminal`:
  - `anUnsupportedLoginRecordsTheFailure`
  - `anUnsupportedLogoutRecordsTheFailure`
  - `anUnsupportedTerminalLoginRecordsTheFailure`
  - `eachReasonHasAMessage`
- Update each existing test that expects "no state change" for an unsupported call.
- Command: `swift test --filter ConnectionModel`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [x] Write the four failing tests.
- [x] Add `Reason.unsupported(method:)` and `Reason.message`.
- [x] Record the failure in the three calls, and update the doc comments.
- [ ] Tell agentviewkit-a3 the commit when it is pushed.
