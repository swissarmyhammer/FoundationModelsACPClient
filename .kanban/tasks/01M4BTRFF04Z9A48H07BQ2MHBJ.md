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
- actor: claude-code
  id: 01m4bw7psf6bratg5v2tbeetk8
  text: |-
    ### commit — changed
    - evidence: 6afd746 feat(model)!: record an unsupported login, logout or terminal login in authState
    - next: review
  timestamp: 2026-10-07T19:07:54.031472+00:00
- actor: claude-code
  id: 01m4bwhtpwxraxjpnpf9c68dyh
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (6afd746): 5 findings (5 confirmed, 1 refuted) — ConnectionModel+Initialize.swift:206, ConnectionModel+Initialize.swift:232, ConnectionModelInitializeTests.swift:80, ConnectionModelInitializeTests.swift:86, ConnectionModelTerminalAuthTests.swift:75
    - next: implement the 5 open items in "Review Findings (2026-10-07 14:08)". The two completeness findings agree with the task "Out of scope" rule: a call with no open connection must still throw ConnectionError.closed and must not change authState. The open subtask "Tell agentviewkit-a3 the commit" is for the orchestrator after the push.
  timestamp: 2026-10-07T19:13:25.724258+00:00
- actor: claude-code
  id: 01m4bwjebze76g7sapmkhh5gwb
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files
    - test: green — swift test, 577 tests in 49 suites pass; IntegrationTests build passes
    - commit: 6afd746
    - review: findings — Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift:206, Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift:232, Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift:80, Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift:86, Tests/FoundationModelsACPClientTests/Model/ConnectionModelTerminalAuthTests.swift:75
  timestamp: 2026-10-07T19:13:45.855811+00:00
- actor: claude-code
  id: 01m4bx1pkkrymghx0xrxh153bh
  text: |-
    Review findings (2026-10-07 14:08), implementation:
    - Findings 1 and 2: `login(_:)` and `logout(_:)` now call `openConnection()` first, and then do the capability check. Thus a call with no open connection always throws `ConnectionError.closed` and records nothing, also when the call is unsupported. The doc comments now say this order, and put `ConnectionError.closed` first in `- Throws:`.
    - RED: new tests `anUnsupportedLoginWithNoOpenConnectionKeepsTheAuthState` and `anUnsupportedLogoutWithNoOpenConnectionKeepsTheAuthState` failed: they got `ConnectionModelError.unsupported` and `authState == .failed(...unsupported...)`. GREEN: the 2 tests passed after the order change.
    - `loginWithTerminal(_:runner:)` does not have the same order problem. It does not call `openConnection()`, because it sends no ACP request. With no open connection, it uses the auth methods and `hasAdvertisedTerminalAuth` of the last `initialize` (`connect` resets them, a close does not). Before this task it also never threw `ConnectionError.closed`, so the out-of-scope rule does not apply to it. I added a doc sentence about this, and the test `aTerminalLoginWithNoOpenConnectionRunsTheMethod` that pins it (it passed at once: it documents behavior that already existed).
    - Findings 3 to 5: new shared file `Tests/FoundationModelsACPClientTests/Model/AuthFailureFixtures.swift` with `AuthFailureFixtures.unsupportedFailure(of: AuthFailure.Operation, method: String) -> AuthFailure`. `InitializeFixtures.unsupportedLoginFailure(of:)`, `InitializeFixtures.unsupportedLogoutFailure` and `TerminalAuthFixtures.unsupportedFailure(of:)` stay in their files as per-case values, and each one is now built from the shared helper. No copy of the construction stays.
    - Also: new `ConnectedModel.closeAgentEnd()` (closes the agent end and waits for `.disconnected`). The private helper `disconnectedModel(authMethods:)` in the initialize tests and the new terminal test use it, so the close-and-wait lines are not copied again. `aLoginWithNoOpenConnectionKeepsTheAuthState` now uses `disconnectedModel(authMethods:)`.
    - Other calls (`refreshSessions`, `deleteSession`, and so on) also use `requireCapability` before `openConnection()`. They change no state when unsupported, so they have no such problem. I did not change them.
  timestamp: 2026-10-07T19:22:05.811342+00:00
- actor: claude-code
  id: 01m4bx1tc0ca0t0t3r3x1rapb4
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+TerminalAuth.swift, Tests/FoundationModelsACPClientTests/Model/AuthFailureFixtures.swift (new), Tests/FoundationModelsACPClientTests/Model/ConnectedModel.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelTerminalAuthTests.swift. `swift build`: complete. `swift test`: 580 tests in 49 suites passed, 0 failed (577 before, 3 new). `swift build --package-path IntegrationTests --build-tests`: complete. The only warning is the accepted MLX warning "missing creator for mutated node". All 5 findings of "Review Findings (2026-10-07 14:08)" are checked.
    - next: /review. The task stays in doing. The subtask "Tell agentviewkit-a3 the commit" stays open for the orchestrator. Nothing is committed.
  timestamp: 2026-10-07T19:22:09.664731+00:00
- actor: claude-code
  id: 01m4bx627rtevbgceav7w78yfs
  text: |-
    ### test — green
    - evidence: swift build — complete, 0 warnings in package code. swift test — 580 tests in 49 suites passed, 0 failed, 0 skipped. swift build --package-path IntegrationTests --build-tests — complete, 0 warnings in package code.
    - note: only warning is "missing creator for mutated node" from the MLX bundle. The task accepts it.
    - next: review
  timestamp: 2026-10-07T19:24:28.792150+00:00
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

## Review Findings (2026-10-07 14:08)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift:206` `completeness/public-output-contract` — The unsupported check in login(_:) runs before openConnection(). With no open connection and a method id the agent does not list, the call now throws ConnectionModelError.unsupported and sets authState to .failed. Before this change it threw ConnectionError.closed and kept the state. The doc at line 198 says that with no open connection the call sends nothing and changes no state, which is false for this path. Call openConnection() before the canLogin guard so that a closed connection still throws ConnectionError.closed and changes no state, or narrow the doc at :198. Add a test that calls login with an unlisted method and no open connection, and asserts the error and authState.
- [x] `Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift:232` `completeness/public-output-contract` — The canLogout guard in logout(_:) runs before openConnection(). With no open connection and canLogout false, the call now throws ConnectionModelError.unsupported and sets authState to .failed, where it used to throw ConnectionError.closed and keep the state. The doc at line 225 says that with no open connection the call changes no state, which is false for this path. Call openConnection() before the canLogout guard so that a closed connection still throws ConnectionError.closed, or narrow the doc at :225. Add a test for logout with no capability and no open connection that asserts the thrown error and authState.
- [x] `Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift:80` `reuse/reuse` — InitializeFixtures.unsupportedLoginFailure(of:) builds the same AuthFailure shape as TerminalAuthFixtures.unsupportedFailure(of:). Only the operation case and the method differ. Two copies of the same construction can drift apart. Use one shared helper that takes the operation and the method, and build the login, logout and terminal-login failures from it.
- [x] `Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift:86` `reuse/reuse` — InitializeFixtures.unsupportedLogoutFailure is a static constant that repeats the unsupported-failure construction. It is the logout form of the same pattern that the login and terminal-login fixtures use. Build this constant from the same shared unsupported-failure helper, passing the logout operation and ConnectionModelError-independent method id of auth/logout.
- [x] `Tests/FoundationModelsACPClientTests/Model/ConnectionModelTerminalAuthTests.swift:75` `reuse/reuse` — TerminalAuthFixtures.unsupportedFailure(of:) builds the same AuthFailure as InitializeFixtures.unsupportedLoginFailure(of:). Only the operation case and the method differ. Two copies of the same construction can drift apart. Use one helper that takes the operation and the method, for example unsupportedFailure(of: AuthFailure.Operation, method: String), in a shared fixture. Then build the login, logout and terminal-login failures from it. Keep the per-case constants in their own files.
