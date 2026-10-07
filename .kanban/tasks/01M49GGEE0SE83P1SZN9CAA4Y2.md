---
assignees:
- claude-code
depends_on:
- 01M49GF51TG4H90K3EX73C1NKK
position_column: todo
position_ordinal: '8980'
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

- [ ] With a fake runner that gives 0, `authState` is `.reconnectRequired(methodId)`, and no ACP frame goes out.
- [ ] After `connect(over:)` with a new transport and `initialize(_:)`, `authState` is `.authenticated(methodId)`.
- [ ] The runner gets the `args` of the method and its `env` as a dictionary.
- [ ] A non-zero status, a `nil` status, a runner error, and a cancel each give `.failed` with operation `.terminalLogin(methodId)`, and the call throws.
- [ ] With no `auth.terminal` in the last `initialize` request, or with an id that is not a listed terminal method, the call throws `unsupported` and the runner is not called.

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

- [ ] Write the eight failing tests.
- [ ] Add `TerminalAuthRunner` and `AuthState.reconnectRequired`.
- [ ] Add `loginWithTerminal(_:runner:)`, with the capability and method checks.
- [ ] Keep `pendingTerminalLogin` across `connect`, and apply it in `initialize`.
- [ ] Document the host duties: the runner, `auth.terminal`, the reconnect, the retry.
