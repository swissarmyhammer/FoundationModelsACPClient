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
- actor: claude-code
  id: 01m7vs09yzrzs7w45sqpw5hhpd
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (bc95c6e). 1 finding, 1 confirmed, 0 refuted. IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/LiveAgentServerBuild.swift:191 (reuse/reuse).
    - next: Put the shared process and stderr log steps of `runToExit` and `runSwiftBuild` into one private helper. Keep the non-zero status throw in `runSwiftBuild`. Then do the review again.
  timestamp: 2026-11-20T06:06:22.175379+00:00
- actor: claude-code
  id: 01m7vs0rd75zc6gcz06j8bsdrr
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files (ServerStart.swift, LiveAgentServer.swift, GraphQLTunnelServer.swift, LiveAgentServerBuild.swift, ServerStartFailureTests.swift); the new test was red (signal 5, Fatal error) and then green
    - test: green — root swift test 961 passed; both builds OK; the new test passed (2 cases); GraphQLTunnelTests 10 passed; only the allowed MLX warning
    - commit: bc95c6e
    - review: findings — IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/LiveAgentServerBuild.swift:191
  timestamp: 2026-11-20T06:06:36.967464+00:00
- actor: claude-code
  id: 01m7vs6g5bm9je2d62v9vxhay4
  text: |-
    Finding reuse/reuse in LiveAgentServerBuild.swift is fixed. The new private helper `runProcess(_:arguments:standardOutput:errorLogName:) -> Exit` makes the stderr log file, sets the `Process`, starts it through `Self.run`, waits for the end, and reads the stderr text. `runSwiftBuild` and `runToExit` both call it. The throw on a non-zero status stays in `runSwiftBuild`. The helper gives the `Exit` struct that already existed, so no new result type is necessary. One change of behavior: stdin of `swift build` is now the null device (before, it was the stdin of the test). `swift build` does not read stdin.

    ### implement — changed
    - evidence: 1 file — IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/LiveAgentServerBuild.swift. `timeout 1800 swift build --build-tests --package-path IntegrationTests`: build complete, only the MLX warning. `timeout 1800 swift test --package-path IntegrationTests --filter aServerWithAWrongArgumentListExitsWithStatusOneAndTellsTheReason`: 1 test, 2 cases, passed. Root `timeout 1800 swift test`: 961 tests in 79 suites passed, only the MLX warning.
    - next: review. "Push main" stays open.
  timestamp: 2026-11-20T06:09:45.131062+00:00
- actor: claude-code
  id: 01m7vsa9xnf6vypnbq6kez89gd
  text: |-
    ### test — green
    - evidence: `timeout 1800 swift test` (root): 961 tests in 79 suites passed. `swift build --build-tests --package-path IntegrationTests`: build complete. Filtered integration run (wrong-argument-list exit status, GraphQLTunnelTests, aConnectionModelRunsOneTurnAgainstARealAgent): 12 tests in 3 suites passed. Zero failures, zero skipped. Only warning: the allowed MLX "missing creator for mutated node" for mlx-swift_Cmlx.bundle.
    - next: review
  timestamp: 2026-11-20T06:11:49.813521+00:00
- actor: claude-code
  id: 01m7vsavgk3pf6qmbm668nyps2
  text: |-
    ### commit — changed
    - evidence: local commit "refactor(integration): share one runProcess helper". It holds LiveAgentServerBuild.swift and the .kanban files. No push.
    - next: review
  timestamp: 2026-11-20T06:12:07.827670+00:00
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

## Review Findings (2026-11-20 00:04)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/LiveAgentServerBuild.swift:191` `reuse/reuse` — `runToExit` rebuilds the same process setup that `runSwiftBuild` already has: it makes a stderr log file with `makeEmptyLogFile`, creates a `Process`, sets `executableURL` and `arguments`, wires the stderr `FileHandle`, calls `Self.run(process)`, and reads the stderr text back with `String(contentsOf:)`. A second copy of this sequence means the process-and-log handling now lives in two places and can diverge. The part that differs (the `swift` launcher, the stdout log, the throw on non-zero status) could be a parameter of one shared helper. Extract the shared part into one private helper, for example `runProcess(executable:arguments:stdout:) -> (status, reason, stderr)`, that owns the log file, the `Process` configuration, and the stderr read. Have `runSwiftBuild` and `runToExit` each call it with their own launcher, arguments, and stdout choice. Keep the non-zero status throw in `runSwiftBuild`.
