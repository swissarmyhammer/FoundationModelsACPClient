---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7vr44njdg880h2w1v6vzeee
  text: |-
    Research:
    - Both `@main` types (`LiveAgentServer`, `GraphQLTunnelServer`) use `static func main() async throws`. All start work (LaunchArguments, IntegrationAgentHome.make, ConfigurationLoader, RoutedACPAgent.init, ComposedAgent.compose, KanbanHost session) can throw. The serve part (connection.closed, waitForConnectionTeardown, closeOpenSessions, board.close) does not throw. Thus `main` can become `async` with no `throws`, and the compiler then makes sure that no error gets to the runtime trap.
    - `AgentProcess` of the library gives the child the stderr of the test process, so a test cannot read the stderr through it. The new test uses `LiveAgentServerBuild.makeExecutable` for the path and a Foundation `Process` with stderr to a log file in the root directory. `Process.terminationReason` tells `.exit` from `.uncaughtSignal`.
    - A wrong argument list (no arguments) gets to the start error at once, with no model load. Today the Swift runtime writes "Fatal error: Error raised at top level" and the process stops on a signal.
    - Plan: one helper in `LiveAgentServerSupport` that runs the start closure, and for an error writes one line `<executable>: <reason>` to stderr and calls `exit(1)`. The test is parameterized over the two server products, so it covers both `@main` types.
  timestamp: 2026-11-20T05:50:59.250929+00:00
- actor: claude-code
  id: 01m7vrm2n51y9t06wswh9h50c6
  text: |-
    Implementation:
    - New `ServerStart.make(isolation:_:)` in `LiveAgentServerSupport/ServerStart.swift`. It runs the start closure. For an error it writes `<process name>: <reason>` as one line to stderr and calls `exit(1)` (`ServerStart.failureStatus`). The `isolation: isolated (any Actor)? = #isolation` parameter is necessary: without it, Swift 6 gives "sending value of non-Sendable type" because `main` is on the main actor and the closure crosses into a nonisolated async function.
    - Both `main` functions are now `static func main() async` with no `throws`. Thus the compiler makes sure that no error gets out of `main`. The serve part stays outside the closure, so the normal end of the connection is not caught. `GraphQLTunnelServer` has a new `makeAgent(_:)` that gives `(composed, board)`.
    - Test: `ServerStartFailureTests.aServerWithAWrongArgumentListExitsWithStatusOneAndTellsTheReason`, parameterized over the two server products. New helper `LiveAgentServerBuild.runToExit(_:arguments:)` (stderr to a log file, stdin and stdout to the null device), and a shared `makeEmptyLogFile(named:)` that `runSwiftBuild` also uses now.
    - RED before the change: both cases stopped on signal 5 with "Swift/ErrorType.swift:254: Fatal error: Error raised at top level: usage: ... (got 0 arguments)".
    - The GraphQL tunnel tests were not run in this step (the instructions named only the turn test). They start the server with the same `main` serve path.
  timestamp: 2026-11-20T05:59:41.477624+00:00
- actor: claude-code
  id: 01m7vrm6fekv58y357wc3zycxq
  text: |-
    ### implement — changed
    - evidence: 5 files — IntegrationTests/LiveAgentServer/Sources/LiveAgentServerSupport/ServerStart.swift (new), IntegrationTests/LiveAgentServer/Sources/live-agent-server/LiveAgentServer.swift, IntegrationTests/LiveAgentServer/Sources/graphql-tunnel-server/GraphQLTunnelServer.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/ServerStartFailureTests.swift (new), IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/LiveAgentServerBuild.swift. `swift build --package-path IntegrationTests/LiveAgentServer` OK; `swift build --build-tests --package-path IntegrationTests` OK; new test RED (2 cases, 6 issues, signal 5) then GREEN (2 cases passed); `aConnectionModelRunsOneTurnAgainstARealAgent` passed; root `swift test` 961 tests in 79 suites passed. Only warning: MLX "missing creator for mutated node".
    - next: /review. Not committed, not pushed. "Push main" stays unchecked.
  timestamp: 2026-11-20T05:59:45.390579+00:00
- actor: claude-code
  id: 01m7vrvt8k8f74b1y9cn2n7q6b
  text: |-
    ### test — green
    - evidence: root `swift test` 961 tests in 79 suites passed; `swift build` of LiveAgentServer and `swift build --build-tests` of IntegrationTests both complete with zero errors; filter aServerWithAWrongArgumentListExitsWithStatusOneAndTellsTheReason 1 test (2 cases) passed; filter GraphQLTunnelTests 10 tests passed. Only warning: the allowed MLX "missing creator for mutated node" warning.
    - next: review
  timestamp: 2026-11-20T06:03:55.027861+00:00
- actor: claude-code
  id: 01m7vrwjcy80st9q82vpyjwjza
  text: |-
    ### commit — changed
    - evidence: local commit fix(integration): exit 1 with one stderr line on a server start error (not pushed)
    - next: review
  timestamp: 2026-11-20T06:04:19.742149+00:00
position_column: doing
position_ordinal: '80'
title: 'LiveAgentServer: the @main of each test server catches a start error, writes the reason to stderr and exits 1'
---
## Problem

CI run 44584505762: the live test server stopped with a Swift runtime trap, not with a clear error:

```
Swift/ErrorType.swift:254: Fatal error: Error raised at top level: profile "large" did not resolve: ResolutionFailure: profile "large" cannot co-fit a budget of 26800603136 bytes.
```

The trap is in this repo. `IntegrationTests/LiveAgentServer/Sources/live-agent-server/LiveAgentServer.swift:88` is `@main` with `static func main() async throws`. The `ProfileResolutionError` of `RoutedACPAgent.init` (and each other start error: file write, configuration load) escapes `main`, and the runtime traps. `acp-agent` of FoundationModelsACPAgent catches the same error, writes the reason to stderr, and exits 1 (a test there guards it). Source: foundationmodelsacpagent-9e, 2026-11-19. The profile cause itself is fixed in ^7ar26sh and in their ^8a6cykg.

`IntegrationTests/LiveAgentServer/Sources/graphql-tunnel-server/GraphQLTunnelServer.swift:41` has the same `static func main() async throws` shape.

## Change

1. In each `@main` of `IntegrationTests/LiveAgentServer` (live-agent-server, graphql-tunnel-server), catch an error of the start (argument parse, agent make, configuration load), write one line with the reason to stderr, and exit with status 1. Do not catch the normal end of the connection.
2. Share one small helper in `LiveAgentServerSupport` if both servers need the same code. Do not write a copy.
3. Comments in STE.

## Tests

- [x] A test (in `IntegrationTests`) starts the live server with a wrong argument list, or a configuration that cannot resolve, and sees exit status 1 and the reason on stderr, not a trap (no "Fatal error" text, and the exit is not a signal).
- [x] The integration tests that start the server still pass.

## Acceptance

- [x] `swift build --package-path IntegrationTests/LiveAgentServer` and the root `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`.