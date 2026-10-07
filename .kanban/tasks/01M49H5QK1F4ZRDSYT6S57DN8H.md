---
assignees:
- claude-code
position_column: todo
position_ordinal: 8b80
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

- [ ] An agent that lists only a terminal method gives `canLogout == true` and `canLogin == false`.
- [ ] An agent that lists an agent method gives `canLogin == true` and `canLogout == true`.
- [ ] No auth methods gives `false` for both.
- [ ] `login(_:)` with a terminal method id, or with an id that the agent does not list, throws `unsupported`, sends no frame, and keeps `authState`.
- [ ] `login(_:)` with an agent method id works as now.

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

- [ ] Write the five failing tests.
- [ ] Correct `canLogout` and add `canLogin`.
- [ ] Add the method check to `login(_:)`.
- [ ] Update the rule comment and the existing expectations.
