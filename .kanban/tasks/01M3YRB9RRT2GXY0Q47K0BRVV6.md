---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m41cm8yarhnyws744v46ztjq
  text: |-
    Research (pin 60854b6 of FoundationModelsACP, the checkout in .build matches Package.resolved):
    - `InitializeResponse` has `info`, `protocolVersion`, `authMethods: [AuthMethod]?`, `capabilities: AgentCapabilities` (not optional).
    - `AgentCapabilities` has `auth: AgentAuthCapabilities?` (only `_meta`), `session: SessionCapabilities?`.
    - `SessionCapabilities` has `additionalDirectories`, `delete`, `mcp`, `prompt`. There is NO `list`, `resume` or `close` field.
    - Upstream `Agent.swift` says: `session/list`, `session/resume` and `session/close` are the session baseline. A non-nil `capabilities.session` advertises them. `session/delete` is gated by `capabilities.session.delete`.
    - There is NO logout capability field. `AgentAuthCapabilities` says: `auth/login` and `auth/logout` are advertised by a non-empty `authMethods` list. `Agent.swift` says: an agent with no entry, or with `terminal` entries only, keeps the method-not-found default for login and logout.
    - Thus the Bools come from these upstream rules, not from invented fields: canListSessions / canResumeSessions / canCloseSessions = `capabilities.session != nil`; canDeleteSessions = `capabilities.session?.delete != nil`; canLogout = `authMethods` holds one entry that is not `.terminal`.
    - `AuthMethod` = `.terminal`, `.agent`, `.unknown(String, JSONValue)`. `LoginAuthRequest(methodId:meta:)`, `LogoutAuthRequest(meta:)`, both responses hold `_meta` only.
    - `ClientSideConnection.loginAuth/logoutAuth` throw `RequestError` (= `ACPError`, Hashable) on a peer error, or `ConnectionError` on disconnect. Wire names: `auth/login`, `auth/logout`.
    - `ScriptedStubAgent` answers initialize with empty capabilities and does not implement login/logout. It records `receivedMeta` per method; the new tests count requests from that record.
  timestamp: 2026-10-03T17:22:44.298569+00:00
- actor: claude-code
  id: 01m41cvynwqcgzacs5mad1frkw
  text: |-
    ### implement — changed
    - evidence: `swift build` complete (only the accepted MLX "missing creator for mutated node" warning). `swift test --filter ConnectionModelInitializeTests`: 15 tests, 15 pass. Full `swift test`: 443 tests in 37 suites, 0 failures; the only warnings are the accepted MLX warning and the permitted `SessionUpdateAggregator` deprecation.
    - files (new): Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift, Sources/FoundationModelsACPClient/Model/AuthState.swift, Sources/FoundationModelsACPClient/Model/ConnectionModelError.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift.
    - files (changed): Sources/FoundationModelsACPClient/Model/ConnectionModel.swift (stored `initializeResponse` and `authState`; `connection` is now `private(set)`, so the extension can read it; `connect` sets both back to their start values), Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift (new `capabilities`, `authMethods`, `loginError` init parameters with defaults; `loginAuth` and `logoutAuth` that record the request).
    - upstream gap (alpha.7, pin 60854b6): the schema has NO capability field for `session/list`, `session/resume`, `session/close`, or `auth/logout`. No field was invented. The flags use the advertisement rules that upstream documents: list/resume/close = `capabilities.session != nil` (session baseline, `Agent.swift`); delete = `capabilities.session?.delete != nil`; logout = an `authMethods` entry that is not `.terminal` (`InitializeResponse.authMethods` and `Agent.loginAuth/logoutAuth` docs). Thus `canListSessions`, `canResumeSessions` and `canCloseSessions` always have the same value.
    - decisions: the Bools, `agentCapabilities` and `authMethods` are computed from the stored `initializeResponse` (one source of truth; Observation tracks them through it). `login` sets `.failed` only for a `RequestError` of the agent; a `ConnectionError` changes no state. A call with no open connection throws `ConnectionError.closed` (upstream type). `login` does not gate on `canLogout`, because the card names the gate for logout only.
    - rules: the dump of the validator rules was 12,098 lines and held rules for all languages. I read the generic rules and the Swift rules; I did not read the Dart, Go, Python, Rust and TypeScript tool sections.
    - next: `/review`.
  timestamp: 2026-10-03T17:26:55.932525+00:00
- actor: claude-code
  id: 01m41d0gakdyer1ejqma90gqb8
  text: |-
    ### test - green
    - evidence: swift build ok. swift test: 443 tests in 37 suites passed. swift build --package-path IntegrationTests ok. swift test --package-path IntegrationTests: 103 tests in 14 suites passed. 0 failed, 0 skipped. Only accepted warnings: mlx-swift bundle warning and SessionUpdateAggregator deprecation.
    - next: review
  timestamp: 2026-10-03T17:29:25.075992+00:00
- actor: claude-code
  id: 01m41d0vd999sy6y3zh7htssac
  text: |-
    ### commit — changed
    - evidence: one local commit "feat(model): add initialize, capability flags and auth to ConnectionModel". Tests: swift test 443/443, IntegrationTests 103/103. Not pushed.
    - next: review
  timestamp: 2026-10-03T17:29:36.425386+00:00
- actor: claude-code
  id: 01m41d1v0g6y7w3tpwrssrk15q
  text: 'UPSTREAM CONFIRMATION (foundationmodelsacp-c7, 2026-10-03): the capability rules are correct for alpha.7. The stable and the unstable schema have no fields for list, resume, close or logout (unstable adds only `session.fork`). The `SessionCapabilities` type text says `{}` means the baseline session methods: session/new, session/list, session/resume, session/close, session/prompt, session/cancel, session/update. Thus `capabilities.session != nil` gives canList/canResume/canClose = true. Known upstream text conflict: the `AgentCapabilities.session` field text lists a smaller baseline (new, prompt, cancel, update); keep the current rule, the peer will tell us if upstream changes. Delete: `session.delete != nil`. Logout: a non-empty `authMethods` list advertises auth/login and auth/logout; a `terminal` method never opens an auth session, so "an authMethods entry that is not terminal" is right.'
  timestamp: 2026-10-03T17:30:08.784190+00:00
- actor: claude-code
  id: 01m41d6h2vn3stm9qxx9591wt1
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit ecb9b87). 6 files reviewed, 7 validator runs attempted, 0 failed. Counts: 0 findings, 0 confirmed, 0 refuted. The 4 `.kanban/` files are excluded by `.reviewignore`. The task has no earlier `## Review Findings` sections.
    - next: none. The task is in done.
  timestamp: 2026-10-03T17:32:42.459616+00:00
- actor: claude-code
  id: 01m41d6vjfkynxvdgkqb4646h1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files (ConnectionModel+Initialize.swift, AuthState.swift, ConnectionModelError.swift, 15 new tests)
    - test: green — swift test 443/443, IntegrationTests 103/103
    - commit: ecb9b87 feat(model): add initialize, capability flags and auth to ConnectionModel
    - review: clean — task moved to done
  timestamp: 2026-10-03T17:32:53.199627+00:00
depends_on:
- 01M3YR1M92146TWJC24JGE1QVF
position_column: done
position_ordinal: c380
title: 'Model: ConnectionModel initialize, capability flags, auth state, login and logout'
---
## What
Add initialize and auth to `ConnectionModel` in `Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift`.

- [x] `initialize(_ request: InitializeRequest) async throws -> InitializeResponse`: stores `initializeResponse`, `agentCapabilities`, `authMethods`, and the Bools `canListSessions`, `canResumeSessions`, `canCloseSessions`, `canDeleteSessions`, `canLogout` (one Bool for each optional agent capability in alpha.7; all are false before initialize).
- [x] `ConnectionModelError.unsupported(method: String)` and an internal `requireCapability(_:method:)`: a method whose capability is false throws it and sends nothing. The factory, list and delete tasks use it.
- [x] `authState: AuthState` with `.unknown` (before initialize), `.notRequired` (the agent lists no auth methods), `.required(methods)` (methods are listed and no login succeeded), `.authenticated(methodId)`, `.failed(RequestError)`.
- [x] `login(_ request: LoginAuthRequest) async throws` sends `connection.loginAuth`, and sets `.authenticated` or `.failed`. `logout(_ request: LogoutAuthRequest) async throws` requires `canLogout`, sends `connection.logoutAuth`, and sets `.required(methods)`.

## Acceptance Criteria
- [x] Each capability flag matches the scripted initialize response, and is false before initialize.
- [x] An unsupported method throws `.unsupported` and the agent receives no request.
- [x] `authState` follows the transitions above for success and failure of login and logout.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift` over `InMemoryTransport.pair()` with `ScriptedStubAgent`: the flags for a full and an empty capability set; `requireCapability` sends nothing (the stub counts requests); the login success and failure; logout; logout with no capability.
- [x] `swift test --filter ConnectionModelInitializeTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.