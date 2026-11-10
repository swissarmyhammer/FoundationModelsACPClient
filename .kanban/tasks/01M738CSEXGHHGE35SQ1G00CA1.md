---
assignees:
- claude-code
depends_on:
- 01M73039GY1BE9R2EA39FJEFGG
position_column: todo
position_ordinal: '8680'
title: 'LiveAgentServer: pass mode: .open explicitly to RoutedACPAgent and ComposedAgent.compose'
---
## What
FoundationModelsACPAgent d3e0463 (^xfeamnv) gives `RoutedACPAgent.init` and `ComposedAgent.compose` a `mode: ToolMode` parameter. A temporary default `.open` is there now, so that no caller breaks. The default goes later. Thus each call must give the mode explicitly (request of testudoapp-75, 2026-11-10).

- [ ] `IntegrationTests/LiveAgentServer/Sources/live-agent-server/LiveAgentServer.swift:92`: add `mode: .open` to `RoutedACPAgent(...)`.
- [ ] `IntegrationTests/LiveAgentServer/Sources/graphql-tunnel-server/GraphQLTunnelServer.swift:44`: add `mode: .open` to `ComposedAgent.compose(...)`.
- [ ] `ToolMode` is in FoundationModelsExtras. Add `import FoundationModelsExtras` where it is necessary, and check that `IntegrationTests/LiveAgentServer/Package.swift` gives each of the two targets the `FoundationModelsExtras` product.
- [ ] Update `IntegrationTests/LiveAgentServer/Package.resolved` (and `IntegrationTests/Package.resolved` if needed) so that FoundationModelsACPAgent is at d3e0463 or later.

## Acceptance Criteria
- [ ] Both calls give `mode: .open`.
- [ ] `swift build --package-path IntegrationTests/LiveAgentServer` passes with no new warnings.
- [ ] The integration tests pass.

## Tests
- [ ] Run `swift test --package-path IntegrationTests` → 23/23 pass. If only the known flaky test `anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall` (task 01M737WW16) times out, run the package again.
- [ ] Send the commit to testudoapp-75.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1