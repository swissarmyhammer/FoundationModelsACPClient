---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4b9nn1n4k9yyqsh2ceq7wgc
  text: |-
    Research:
    - `canLogout` reads `AuthMethod.isSentToLogin` (a fileprivate extension at the end of `ConnectionModel+Initialize.swift`). `.unknown` counts as sent to login now. No other source file reads `canLogout`. `Sources/AcpClientCore/ProbeReport.swift` does not read it, so it needs no change.
    - `logout(_:)` calls `requireCapability(canLogout, ...)` before `openConnection()`. `login(_:)` will use the same order.
    - Existing tests that the change affects: `terminalAuthMethodsAloneCannotLogout` (expects `!canLogout` for a terminal-only agent) and `aLogoutWithNoCapabilityKeepsTheAuthState` (uses a terminal-only agent to make logout unsupported). `CapabilityFlags` in the test file needs `canLogin`.
    - Other test files call `login(InitializeFixtures.login)` (AuthRequired, Elicitation, ModelRequestSpan tests). Each one must list the agent method, or the new check refuses the login.
    - `AuthMethodAgent.methodId` gives the id of an agent method.
  timestamp: 2026-10-07T13:43:28.053017+00:00
- actor: claude-code
  id: 01m4ba2vxwy2m0sqx243kp1qxc
  text: |-
    Implementation notes:
    - RED: `swift test --filter ConnectionModelInitializeTests` failed to compile, because `ConnectionModel.canLogin` did not exist.
    - GREEN: `canLogout` is now `!authMethods.isEmpty`. The new `canLogin` is true when a listed method is `.agent`. `login(_:)` calls `requireCapability(canLogin(with: request.methodId), method: ClientRequestSpan.Method.login)` before `openConnection()`, so a terminal id or an unlisted id sends nothing and keeps `authState`. The fileprivate `AuthMethod.isSentToLogin` is replaced by `loginMethodId: AuthMethodId?` (the id for `.agent`, `nil` for `.terminal` and `.unknown`).
    - Existing tests that changed: `terminalAuthMethodsAloneCannotLogout` is replaced by `aTerminalOnlyAgentCanLogOutButNotLogIn`. `aLogoutWithNoCapabilityKeepsTheAuthState` now uses an agent with no auth methods, because a terminal-only agent now serves logout. `CapabilityFlags` holds `canLogin`.
    - Discovery: the first full run failed 10 tests in `ConnectionModelElicitationTests`. `LoginHarness` sent a login with no initialize and no listed auth method, so the new check refused it. The fix: the stub agent of the harness lists `InitializeFixtures.agentMethod`, and `startLogin()` sends initialize first.
    - `Sources/AcpClientCore/ProbeReport.swift` does not read `canLogout`, so it did not change.
  timestamp: 2026-10-07T13:50:41.084896+00:00
- actor: claude-code
  id: 01m4ba2y2as0119v5gz1av5225
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelElicitationTests.swift. `swift test --filter ConnectionModelInitializeTests`: 27 passed. `swift test`: 549 tests in 46 suites passed, 0 failed. The only warning is the accepted MLX "missing creator for mutated node" warning (^zws9qzt).
    - next: /review. The task stays in doing.
  timestamp: 2026-10-07T13:50:43.274718+00:00
position_column: doing
position_ordinal: '80'
title: 'Model: canLogout follows the ACP rule, and login refuses a terminal method (ACP MUST NOT)'
---
## What

ACP v2 rules (schema `InitializeResponse.authMethods`, `LoginAuthRequest`, `AuthMethodTerminal`; https://agentclientprotocol.com/protocol/v2/authentication):

- "Supplying one or more valid methods means the agent MUST support both `auth/login` and `auth/logout`." "Clients MUST NOT call this method when `authMethods` was omitted or empty."
- For a terminal method: "The client MUST NOT pass this method to `auth/login`."
- `auth/login` takes "an advertised authentication method whose type defines the `auth/login` flow", that is an `agent` method.

The model does not follow these rules now (`Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift`):

- `canLogout` (line 63) is `true` only when a method is not `terminal`. An agent that lists only terminal methods MUST support `auth/logout`, but the model says it cannot. AgentViewKit then hides Sign Out after a terminal login.
- `login(_:)` (line 120) sends any `methodId`, also the id of a terminal method, and also an id that the agent does not list.

1. `canLogout`: `true` when `authMethods` is not empty. Remove `AuthMethod.isSentToLogin` from this check.
2. Add `public var canLogin: Bool` — `true` when `authMethods` has at least one `.agent` method. Keep `.unknown` methods out of `canLogin` (the schema says: ignore an unknown method type or show it generically).
3. `login(_:)`: before the request, throw `ConnectionModelError.unsupported(method: ClientRequestSpan.Method.login)` and send nothing when `request.methodId` is not the id of a listed `.agent` method. A terminal id goes to `loginWithTerminal` (task ^9caa4y2) instead. Do not change `authState` in this case.
4. Update the comment block at the top of `ConnectionModel+Initialize.swift` (lines 7–16) with the corrected rules.
5. Update `Sources/AcpClientCore/ProbeReport.swift` only if it reads `canLogout` (check with `rg canLogout Sources`).

## Acceptance Criteria

- [x] An agent that lists only a terminal method gives `canLogout == true` and `canLogin == false`.
- [x] An agent that lists an agent method gives `canLogin == true` and `canLogout == true`.
- [x] No auth methods gives `false` for both.
- [x] `login(_:)` with a terminal method id, or with an id that the agent does not list, throws `unsupported`, sends no frame, and keeps `authState`.
- [x] `login(_:)` with an agent method id works as now.

## Tests

- Add tests to `Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift`, with `InitializeFixtures` answers that list (a) only a terminal method, (b) an agent method, (c) none, and `connected.receivedMethods` to prove that no frame went out. No sleeps.
  - `aTerminalOnlyAgentCanLogOutButNotLogIn`
  - `anAgentMethodAllowsLoginAndLogout`
  - `noAuthMethodsAllowsNeither`
  - `loginWithATerminalMethodThrowsAndSendsNothing`
  - `loginWithAnUnlistedMethodThrowsAndSendsNothing`
- Update the existing `canLogout` expectations in that file.
- Command: `swift test --filter ConnectionModelInitializeTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [x] Write the five failing tests.
- [x] Correct `canLogout` and add `canLogin`.
- [x] Add the method check to `login(_:)`.
- [x] Update the rule comment and the existing expectations.
