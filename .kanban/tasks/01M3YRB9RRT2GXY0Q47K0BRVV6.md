---
assignees:
- claude-code
depends_on:
- 01M3YR1M92146TWJC24JGE1QVF
position_column: todo
position_ordinal: 8c80
title: 'Model: ConnectionModel initialize, capability flags, auth state, login and logout'
---
## What
Add initialize and auth to `ConnectionModel` in `Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift`.

- [ ] `initialize(_ request: InitializeRequest) async throws -> InitializeResponse`: stores `initializeResponse`, `agentCapabilities`, `authMethods`, and the Bools `canListSessions`, `canResumeSessions`, `canCloseSessions`, `canDeleteSessions`, `canLogout` (one Bool for each optional agent capability in alpha.7; all are false before initialize).
- [ ] `ConnectionModelError.unsupported(method: String)` and an internal `requireCapability(_:method:)`: a method whose capability is false throws it and sends nothing. The factory, list and delete tasks use it.
- [ ] `authState: AuthState` with `.unknown` (before initialize), `.notRequired` (the agent lists no auth methods), `.required(methods)` (methods are listed and no login succeeded), `.authenticated(methodId)`, `.failed(RequestError)`.
- [ ] `login(_ request: LoginAuthRequest) async throws` sends `connection.loginAuth`, and sets `.authenticated` or `.failed`. `logout(_ request: LogoutAuthRequest) async throws` requires `canLogout`, sends `connection.logoutAuth`, and sets `.required(methods)`.

## Acceptance Criteria
- [ ] Each capability flag matches the scripted initialize response, and is false before initialize.
- [ ] An unsupported method throws `.unsupported` and the agent receives no request.
- [ ] `authState` follows the transitions above for success and failure of login and logout.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift` over `InMemoryTransport.pair()` with `ScriptedStubAgent`: the flags for a full and an empty capability set; `requireCapability` sends nothing (the stub counts requests); the login success and failure; logout; logout with no capability.
- [ ] `swift test --filter ConnectionModelInitializeTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.