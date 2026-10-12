---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4s4rk2fsk3ernzm1srw6b2k
  text: |-
    Research (implement):
    - SwiftPM 6.4.0-dev. The check is in `createResolvedPackages` of `ModulesGraph+Loading.swift`. It walks `manifest.dependenciesRequired(for: productFilter)`. For a non-root package, that list uses the targets of ALL its products (`targetsRequired(for: self.products)`), not only the product that the test links. `acp-agent`, `acp-print` and `FoundationModelsACPAgentTestSupport` link the client. Thus each graph that holds the agent package gives the warning, also when the test links only the library product.
    - Mirrors do not help: a mirror to a local path needs an absolute path (no relative form), and it is a git checkout of the committed HEAD, not the working tree.
    - `swift package edit` needs a step before `swift test`, and the shared CI workflow has no such step.
    - Decision: option 2. A helper package `IntegrationTests/LiveAgentServer` holds the executable `live-agent-server`: `RoutedACPAgent` with a greedy `Router`, served over stdio. The test builds it with `swift build --package-path`, starts it with `AgentProcess` of this library, and drives it with `ConnectionModel` over the stdio transport. The IntegrationTests graph then holds only the local library (by path) and the wire.
    - Effect on CI: the IntegrationTests graph has no MLX now, so `integration-metallib-glob` must go (the copy step fails with "not found" when the glob matches nothing). The unit job of the shared workflow does not build the helper package; the integration job builds it in each run, inside the test.
  timestamp: 2026-10-12T22:47:03.503066+00:00
- actor: claude-code
  id: 01m4s5k1f8ygrdy274kqenss3x
  text: |-
    Implementation landed (option 2):
    - New package `IntegrationTests/LiveAgentServer` with the executable `live-agent-server`. It writes the user-layer `config.yaml` (Qwen3-4B / Qwen3-1.7B, no code context, no skills marketplaces), builds `RoutedACPAgent` with `Router(samplingMode: .greedy)`, and serves it with `AgentSideConnection(stream: StdioTransport())`. Usage: `live-agent-server <state-directory> <working-directory>`.
    - `IntegrationTests/Package.swift` now depends only on `..` (path) and FoundationModelsACP. FoundationModelsACPAgent, FoundationModelsRouter and the router test support are gone from this graph.
    - New `LiveAgentServerBuild.swift` in the test target: runs `swift build --package-path <LiveAgentServer> --product live-agent-server`, then `--show-bin-path`, through `/usr/bin/env swift`. The output goes to log files under the temporary root, not to the test output, so the MLX warnings of the server build do not show in the test run. A failed build throws an error that holds the log.
    - `LiveAgentTurnTests` starts the server with `AgentProcess`, connects `ConnectionModel` over `agentProcess.transport`, and after `disconnect()` expects that `waitForExit()` is not `.notCollected`. Time limit 20 -> 30 minutes, because it now includes the server build.
    - `.github/workflows/ci.yml`: removed `integration-metallib-glob` (the test process loads no model; the server executable finds the metallib in the Cmlx bundle beside it, proved by the local run). Comments updated.
    Discoveries:
    - MLX stays in the IntegrationTests graph through FoundationModelsExtras of the root package, so the old glob would still match. It is removed only because the xctest no longer loads a model.
    - `swift test --package-path IntegrationTests` still writes "missing creator for mutated node ... mlx-swift_Cmlx.bundle" and the MLX C++17 warnings and `ServiceContext` deprecation warnings on a cold build. These come from the root graph (Extras MLX bundle, library telemetry code) and are not part of this card.
    - The shared workflow unit job builds `IntegrationTests` but not `LiveAgentServer`. A break in the server shows first in the integration job (always runs).
  timestamp: 2026-10-12T23:01:30.216907+00:00
- actor: claude-code
  id: 01m4s5k60hvymnn4pmk13p4r4d
  text: |-
    ### implement — changed
    - evidence: 6 files — IntegrationTests/Package.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/LiveAgentTurnTests.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/LiveAgentServerBuild.swift (new), IntegrationTests/LiveAgentServer/Package.swift (new), IntegrationTests/LiveAgentServer/Sources/live-agent-server/LiveAgentServer.swift (new), .github/workflows/ci.yml. Cold `rm -rf IntegrationTests/.build IntegrationTests/LiveAgentServer/.build && swift test --package-path IntegrationTests`: exit 0, 1 test in 1 suite passed (95.8 s), 0 "Conflicting identity" lines. Root `swift build`: exit 0. Root `swift test`: exit 0, 533 tests in 41 suites passed.
    - next: /review
  timestamp: 2026-10-12T23:01:34.865550+00:00
- actor: claude-code
  id: 01m4s5nmeg4c4998anapf332wa
  text: |-
    ### test — green
    - evidence: `swift test` — 533 tests in 41 suites passed, 0 failed, 0 skipped. `swift test --package-path IntegrationTests` — 1 test in 1 suite passed, 0 failed, 0 skipped. The output has no "Conflicting identity" warning.
    - known warning, tracked elsewhere: MLX "missing creator for mutated node" (one line in each run). Not changed.
    - next: review and commit.
  timestamp: 2026-10-12T23:02:55.184294+00:00
position_column: doing
position_ordinal: '80'
title: Remove the SwiftPM "Conflicting identity for foundationmodelsacpclient" warning of the IntegrationTests package
---
## Problem
`swift test --package-path IntegrationTests` writes this warning two times:
"'foundationmodelsacpagent': Conflicting identity for foundationmodelsacpclient ... This will be escalated to an error in future versions of SwiftPM."

FoundationModelsACPAgent depends on FoundationModelsACPClient by URL. The nested `IntegrationTests` package depends on the root by `path: ".."` (Shape 2 of `../workflows/docs/swift-ci.md`). SwiftPM uses the path dependency (there is no checkout of the URL), so the test is correct today. SwiftPM exempts only a root package from this check (`allowedToOverride = root.manifests.values.contains(node.manifest)` in `ModulesGraph+Loading.swift`), and the nested package is the root.

## Why ^nnd1wxj did not remove it
- The in-process agent needs the agent package in the graph. That gives the warning.
- The `acp-agent` executable has no greedy decoding option, and ^nnd1wxj requires greedy decoding. Also, a build of the executable in this graph gives the same warning.
- A helper package outside the graph (an executable that serves `RoutedACPAgent` with a greedy router, built by `swift build` inside the test) removes the warning, but it adds a second package and a build in the test.

## Options
1. Upstream (FoundationModelsACPAgent): add a greedy option to `acp-agent`, or move the targets that link the client out of the package that holds the library.
2. The helper package described above.
3. Accept the warning, as ^zws9qzt accepts the MLX warning.

## Acceptance criteria
- [x] `swift test --package-path IntegrationTests` writes no "Conflicting identity" warning, and the test still uses the local library.