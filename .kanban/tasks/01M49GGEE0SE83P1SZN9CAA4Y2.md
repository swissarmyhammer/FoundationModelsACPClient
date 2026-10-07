---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4bfq8d9spvtqrbksvratzcx
  text: |-
    Research done.
    - `connect(over:logger:bufferLimits:client:)` in ConnectionModel.swift sets `initializeResponse = nil` and `authState = .unknown`. A stored `pendingTerminalLogin` must go in the class body (an extension cannot hold a stored property).
    - `initialize(_:)` in ConnectionModel+Initialize.swift sets `authState = AuthState(advertising: authMethods)` after the answer.
    - `InitializeRequest.capabilities.auth?.terminal` is `TerminalAuthCapabilities?` (FoundationModelsACP). `AuthMethodTerminal` has `args: [String]?` and `env: [EnvVariable]?` (`name`, `value`).
    - `ACPClient.advertisedCapabilities` omits `auth`, so the test initialize request needs its own capabilities with `auth: AuthCapabilities(terminal: TerminalAuthCapabilities())`.
    - `ConnectionModelError.unsupported(method:)` holds a wire method. Terminal auth has no wire method, so the model needs a named value for this operation.
    - `ConnectedModel(model:makeAgent:)` lets a test connect one model two times, for the reconnect.
    - `UpdateGate` (test support) lets the cancel test hold the fake runner without a sleep.
  timestamp: 2026-10-07T15:29:12.105858+00:00
- actor: claude-code
  id: 01m4bg1d14pfxzaq8e619zgfxy
  text: |-
    Implementation landed (TDD).
    - RED: the new test file failed to compile only because the new API was missing (`TerminalAuthRunner`, `loginWithTerminal`, `AuthState.reconnectRequired`, `ConnectionModelError.terminalAuthFailed`, `ConnectionModelError.terminalAuthOperation`).
    - GREEN: `swift test --filter ConnectionModelTerminalAuthTests` gave 9 of 9 passed. Full `swift test` gave 568 tests in 49 suites passed. The only warning is the accepted MLX "missing creator for mutated node" warning.
    - Decisions to know:
      - `ConnectionModelError.unsupported(method:)` holds a wire method, and terminal auth has none. A new constant `ConnectionModelError.terminalAuthOperation` ("terminal auth") names it.
      - A ninth test, `aRunnerErrorGivesFailedAndThrowsTheError`, covers the "runner error" acceptance item. The card lists no test for that item.
      - A thrown error and a cancel record `.terminal(exitStatus: nil, message: String(describing: error))`. A non-zero status and a nil status record `message: nil`.
      - The model checks cancellation before and after the runner call. Thus a cancel gives `.failed` and `CancellationError` also when the runner ignores the cancel and returns 0.
      - `initialize(_:)` clears `pendingTerminalLogin` after each successful answer, also when the answer no longer lists the method. The card names the clear only for the success branch. This stops an old login from applying on a later connection.
      - `connect(over:...)` resets the recorded `auth.terminal` flag (`advertisedTerminalAuth`), as it resets `initializeResponse`.
      - `AcpClientCore/AgentSession.isUnanswered` switches over `ConnectionModelError` with no default. It got `case .terminalAuthFailed: false`.
      - Docs updated: the `ACPClient.advertisedCapabilities` comment and the plan.md terminal-auth decision now name `loginWithTerminal(_:runner:)`.
  timestamp: 2026-10-07T15:34:44.516529+00:00
- actor: claude-code
  id: 01m4bg1h2cja1tr8pkghebbe66
  text: |-
    ### implement — changed
    - evidence: 10 files. New: Sources/FoundationModelsACPClient/Model/TerminalAuthRunner.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+TerminalAuth.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelTerminalAuthTests.swift. Changed: Model/AuthState.swift, Model/ConnectionModelError.swift, Model/ConnectionModel.swift, Model/ConnectionModel+Initialize.swift, ACPClient.swift, Sources/AcpClientCore/AgentSession.swift, plan.md. `swift test --filter ConnectionModelTerminalAuthTests`: 9 passed, 0 failed. `swift test`: 568 tests in 49 suites passed, 0 failed; the only warning is the accepted MLX warning (task zws9qzt).
    - next: /review. The task stays in doing. Nothing is committed.
  timestamp: 2026-10-07T15:34:48.652683+00:00
- actor: claude-code
  id: 01m4bgwaj6n29ref1zv5fxp0gt
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (48db10c); 1 finding (1 confirmed, 0 refuted) — Sources/FoundationModelsACPClient/Model/ConnectionModel.swift:87 swift/naming-clarity
    - next: rename `advertisedTerminalAuth` to `hasAdvertisedTerminalAuth` in all files, then commit and review again
  timestamp: 2026-10-07T15:49:26.726045+00:00
- actor: claude-code
  id: 01m4bgwpdh4yp8h94pfz3mszcn
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 files
    - test: green — swift test, 568 passed, 0 failed, 0 skipped; IntegrationTests builds
    - commit: 48db10c
    - review: findings — Sources/FoundationModelsACPClient/Model/ConnectionModel.swift:87
  timestamp: 2026-10-07T15:49:38.865712+00:00
- actor: claude-code
  id: 01m4bh52azavw24bx1xjaxzpy6
  text: |-
    Finding swift/naming-clarity done. Renamed `advertisedTerminalAuth` to `hasAdvertisedTerminalAuth` at all 4 sites: the declaration and the reset in `connect(over:...)` (ConnectionModel.swift), the record in `initialize(_:)` (ConnectionModel+Initialize.swift), and the guard in `runnableTerminalMethod(_:)` (ConnectionModel+TerminalAuth.swift). The doc comment holds no old name. No test refers to the property. The other properties that this task added are not Boolean (`pendingTerminalLogin: AuthMethodId?`, `terminalMethod`, `environmentVariables`), so the same cause has no other site. Note: the `files` edit with `replace_all` changed only one site in ConnectionModel.swift; a second edit fixed the reset in `connect`. A check with `rg` after the edits found no old name outside `.kanban/`.

    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+TerminalAuth.swift. `swift test`: 568 tests in 49 suites passed, 0 failed; the only warning is the accepted MLX warning (task zws9qzt).
    - next: /review. The task stays in doing. Nothing is committed.
  timestamp: 2026-10-07T15:54:13.215188+00:00
- actor: claude-code
  id: 01m4bhg6781evt7m95pswgf6nv
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (36f3249), 0 findings (3 files reviewed, 7 validator runs attempted, 0 failed). All prior items are checked.
    - next: none. The task moved to done.
  timestamp: 2026-10-07T16:00:17.640767+00:00
- actor: claude-code
  id: 01m4bhgdr5pa2x3se01vnc0nj4
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 3 files (rename `advertisedTerminalAuth` to `hasAdvertisedTerminalAuth`)
    - test: green — swift test, 568 passed, 0 failed, 0 skipped
    - commit: 36f3249
    - review: clean — 0 findings; the earlier finding at ConnectionModel.swift:87 is checked; task moved to done
  timestamp: 2026-10-07T16:00:25.349679+00:00
depends_on:
- 01M49GF51TG4H90K3EX73C1NKK
position_column: done
position_ordinal: df80
title: 'Model: run a terminal auth method through a host runner, then require a reconnect and an initialize'
---
## What

ACP v2 authentication (https://agentclientprotocol.com/protocol/v2/authentication) gives these rules for a `terminal` auth method (`AuthMethod.terminal(AuthMethodTerminal)`, FoundationModelsACP `Generated/Models.generated.swift:669`):

- The client launches a separate interactive process with the same configured agent program and the same base launch configuration as the ACP connection. It appends the `args` of the method, and applies its `env` over same-named variables.
- Exit status zero is success. A non-zero status, an end with no exit status, or a cancel is failure.
- After the process ends, the client MUST reconnect and initialize the agent again, and then retry the operation that needed auth.
- The client MUST NOT send `auth/login` for a terminal method.
- The agent may list terminal methods only when the client sent `ClientCapabilities.auth.terminal = {}` in `initialize`. The client should send it only when it can reproduce the agent invocation in an interactive terminal.

Thus a successful terminal login does NOT authenticate the open connection. The model cannot reconnect alone: `ConnectionModel.connect(over:...)` gets a transport from the host, so the model does not know the agent command. `AgentProcess` uses pipes and gives no interactive terminal. The host gives a runner and a new transport; the model owns the state.

1. Add `Sources/FoundationModelsACPClient/Model/TerminalAuthRunner.swift`:
   - `public protocol TerminalAuthRunner: Sendable { func runTerminalAuth(arguments: [String], environment: [String: String]) async throws -> Int32? }`. The host appends `arguments` to its agent command, applies `environment` over its launch environment, runs the program in an interactive terminal, and gives the exit status, or `nil` when the process ended with no exit status (a signal). A thrown error means that the program did not start.
2. In `Sources/FoundationModelsACPClient/Model/AuthState.swift`, add `case reconnectRequired(AuthMethodId)`: the terminal login succeeded, and the host must reconnect and initialize.
3. Add `Sources/FoundationModelsACPClient/Model/ConnectionModel+TerminalAuth.swift`:
   - `public func loginWithTerminal(_ methodId: AuthMethodId, runner: any TerminalAuthRunner) async throws`.
   - Throw `ConnectionModelError.unsupported(method:)`, call no runner and change no state when:
     - the last `initialize` request did not send `capabilities.auth?.terminal` (record this value in `initialize(_:)`), or
     - `authMethods` has no `.terminal` method with that id.
   - Convert `env` to `[String: String]` and `args ?? []`, and call the runner. Send no ACP request.
   - Exit status 0: `authState = .reconnectRequired(methodId)`, and keep `methodId` as `pendingTerminalLogin`.
   - Another exit status, `nil`, a thrown error, or a cancel of the calling task: `authState = .failed(AuthFailure(operation: .terminalLogin(methodId), reason: .terminal(exitStatus:message:)))` (type from task ^73c1nkk). Throw `ConnectionModelError.terminalAuthFailed(exitStatus:)`, or the thrown error, or `CancellationError`.
4. In `ConnectionModel+Initialize.swift` and `ConnectionModel.swift`:
   - `connect(over:...)` keeps `pendingTerminalLogin` (now it resets `authState` to `.unknown`).
   - `initialize(_:)`: when `pendingTerminalLogin` is set and the answer still lists that method, set `authState = .authenticated(methodId)` and clear `pendingTerminalLogin`. Otherwise use `AuthState(advertising:)` as now. A later `-32000` changes it to `.required` (tasks ^fxa80af and ^cgznw8q).
5. The model does not retry the failed operation. The host retries it after `initialize`. Document this.

## Acceptance Criteria

- [x] With a fake runner that gives 0, `authState` is `.reconnectRequired(methodId)`, and no ACP frame goes out.
- [x] After `connect(over:)` with a new transport and `initialize(_:)`, `authState` is `.authenticated(methodId)`.
- [x] The runner gets the `args` of the method and its `env` as a dictionary.
- [x] A non-zero status, a `nil` status, a runner error, and a cancel each give `.failed` with operation `.terminalLogin(methodId)`, and the call throws.
- [x] With no `auth.terminal` in the last `initialize` request, or with an id that is not a listed terminal method, the call throws `unsupported` and the runner is not called.

## Tests

- Add `Tests/FoundationModelsACPClientTests/Model/ConnectionModelTerminalAuthTests.swift`, with a fake `TerminalAuthRunner` that records its arguments, two `InMemoryTransport.pair()` connections in sequence to show the reconnect, and `ScriptedStubAgent` with an `initialize` answer that lists one `.terminal` and one `.agent` method. No sleeps.
  - `aZeroExitRequiresAReconnect`
  - `theNextInitializeAfterAReconnectGivesAuthenticated`
  - `theRunnerGetsTheArgsAndTheEnvOfTheMethod`
  - `aNonZeroExitGivesFailedAndThrows`
  - `anEndWithNoExitStatusGivesFailed`
  - `aCancelGivesFailed`
  - `noTerminalCapabilityDoesNotCallTheRunner`
  - `anAgentMethodIdIsNotRunInATerminal`
- Command: `swift test --filter ConnectionModelTerminalAuthTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [x] Write the eight failing tests.
- [x] Add `TerminalAuthRunner` and `AuthState.reconnectRequired`.
- [x] Add `loginWithTerminal(_:runner:)`, with the capability and method checks.
- [x] Keep `pendingTerminalLogin` across `connect`, and apply it in `initialize`.
- [x] Document the host duties: the runner, `auth.terminal`, the reconnect, the retry.

## Review Findings (2026-10-07 10:38)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `plan.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPClient/Model/ConnectionModel.swift:87` `swift/naming-clarity` — Boolean property name should read as an assertion about the receiver. `advertisedTerminalAuth` reads as a bare adjective or past-participle descriptor rather than an assertion. Follow the pattern of Swift API Design Guidelines: `isEmpty`, `isEnabled`, `hasPrefix(_:)`. Rename to `hasAdvertisedTerminalAuth` or `isTerminalAuthAdvertised` so it reads as an assertion: 'has advertised terminal auth' or 'is terminal auth advertised'. Rename `advertisedTerminalAuth` to `hasAdvertisedTerminalAuth`.
