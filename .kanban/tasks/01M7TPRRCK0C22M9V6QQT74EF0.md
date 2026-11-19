---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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

- [ ] A test (in `IntegrationTests`) starts the live server with a wrong argument list, or a configuration that cannot resolve, and sees exit status 1 and the reason on stderr, not a trap (no "Fatal error" text, and the exit is not a signal).
- [ ] The integration tests that start the server still pass.

## Acceptance

- [ ] `swift build --package-path IntegrationTests/LiveAgentServer` and the root `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`.