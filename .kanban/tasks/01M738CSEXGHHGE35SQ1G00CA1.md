---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73axv72tm8pcp8y63vg3rp4
  text: 'Research: The graphql-tunnel-server target has the FoundationModelsExtras product already, but its source has no `import FoundationModelsExtras`. The live-agent-server target does not have the FoundationModelsExtras product, and its source has no import. LiveAgentServer/Package.resolved pins FoundationModelsACPAgent at 51332f3 and FoundationModelsExtras at 0b45545. IntegrationTests/Package.resolved does not pin FoundationModelsACPAgent; it pins FoundationModelsExtras at dbbd53e.'
  timestamp: 2026-11-10T18:18:35.106113+00:00
- actor: claude-code
  id: 01m73bsbtxze1yyzf4tkn2thm8
  text: |-
    Pin update discoveries. `swift package update FoundationModelsACPAgent FoundationModelsExtras` in LiveAgentServer moved ACPAgent 51332f3 -> 728276c (contains d3e0463) and Extras 0b45545 -> 3d0eced. Extras now adds FoundationModelsLlamaCpp and llama-cpp-swift (both in-family). After this, the build failed in sequence on these causes, each one fixed by an in-family move or by a caller change:
    1. FoundationModelsAgents 27418d2: `switch must be exhaustive` (new `ParamType.object` of Extras). Moved to 7ad4293.
    2. FoundationModelsMultitool bf3f072: the same exhaustive switch. Moved to 6e648dc.
    3. ACPAgent ToolCatalog: `extra argument 'templateContext'`. Moved the other in-family pins to main: ACP f249483, ACPClient 4f95d2f, CodeContext 61e8149, Kanban b7d54aa, Router 93cff21, Skills 9f07fb6.
    4. The update of mlx-swift-lm moved mlx-swift (third party) 0.32.3 -> 0.33.0. That is not allowed, so I put mlx-swift-lm (89e3826) and mlx-swift (0.32.3) back. The build passes with them.
    5. `module 'LlamaCppCore' requires feature 'cplusplus'`: added the family C++ interop loop at the end of LiveAgentServer/Package.swift, as the manifests of Router and ACPAgent require of each consumer.
    6. `missing argument for parameter 'projects'`: ACPAgent c247697 makes `projects:` required on `AgentHome.makeCustom`. IntegrationAgentHome now gives the `AgentHome.projectsFolderName` folder of the synced root, as `acp-agent` does.
    IntegrationTests/Package.resolved: only Extras dbbd53e -> 3d0eced moved, plus the two new in-family pins. Both Package.resolved files are gitignored, so the diffs are not in git.
  timestamp: 2026-11-10T18:33:36.861091+00:00
- actor: claude-code
  id: 01m73c0ct0sncngp4zbz94zt7z
  text: |-
    ### implement — changed
    - evidence: 4 files — IntegrationTests/LiveAgentServer/Package.swift (Extras product on live-agent-server; C++ interop loop), Sources/live-agent-server/LiveAgentServer.swift (import, `mode: .open`), Sources/graphql-tunnel-server/GraphQLTunnelServer.swift (import, `mode: .open`), Sources/LiveAgentServerSupport/IntegrationAgentHome.swift (`projects:` of `makeCustom`). Pins (gitignored): LiveAgentServer and IntegrationTests Package.resolved, in-family only. `swift build --package-path IntegrationTests/LiveAgentServer` pass, 0 warnings. `swift build` pass. `swift test` 863/863 pass. `swift test --package-path IntegrationTests` 23/23 pass on run 1. Root Package.resolved did not change.
    - next: /review. The C++ interop loop and the `projects:` change are outside the card text; the pin update made them necessary. "Send the commit to testudoapp-75" is open: no commit in this step.
  timestamp: 2026-11-10T18:37:27.232770+00:00
- actor: claude-code
  id: 01m73cahy5dsmtmr34gjf5jevv
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (10626e4), 4 files reviewed, 0 findings (0 confirmed, 0 refuted, 7 attempted, 0 failed).
    - next: none. The task is in done. The subtask "Send the commit to testudoapp-75" is checked, because the orchestrator sends the commit after the push.
  timestamp: 2026-11-10T18:43:00.165929+00:00
- actor: claude-code
  id: 01m73cavsfzkqpbqr99knxhmyx
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files in IntegrationTests/LiveAgentServer (pins are gitignored)
    - test: green — swift test 863/863, IntegrationTests 23/23
    - commit: 10626e4 (pushed, sent to testudoapp-75 and foundationmodelsacpagent-ec)
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-10T18:43:10.255366+00:00
depends_on:
- 01M73039GY1BE9R2EA39FJEFGG
position_column: done
position_ordinal: ffac80
title: 'LiveAgentServer: pass mode: .open explicitly to RoutedACPAgent and ComposedAgent.compose'
---
## What
FoundationModelsACPAgent d3e0463 (^xfeamnv) gives `RoutedACPAgent.init` and `ComposedAgent.compose` a `mode: ToolMode` parameter. A temporary default `.open` is there now, so that no caller breaks. The default goes later. Thus each call must give the mode explicitly (request of testudoapp-75, 2026-11-10).

- [x] `IntegrationTests/LiveAgentServer/Sources/live-agent-server/LiveAgentServer.swift:92`: add `mode: .open` to `RoutedACPAgent(...)`.
- [x] `IntegrationTests/LiveAgentServer/Sources/graphql-tunnel-server/GraphQLTunnelServer.swift:44`: add `mode: .open` to `ComposedAgent.compose(...)`.
- [x] `ToolMode` is in FoundationModelsExtras. Add `import FoundationModelsExtras` where it is necessary, and check that `IntegrationTests/LiveAgentServer/Package.swift` gives each of the two targets the `FoundationModelsExtras` product.
- [x] Update `IntegrationTests/LiveAgentServer/Package.resolved` (and `IntegrationTests/Package.resolved` if needed) so that FoundationModelsACPAgent is at d3e0463 or later.

## Acceptance Criteria
- [x] Both calls give `mode: .open`.
- [x] `swift build --package-path IntegrationTests/LiveAgentServer` passes with no new warnings.
- [x] The integration tests pass.

## Tests
- [x] Run `swift test --package-path IntegrationTests` → 23/23 pass. If only the known flaky test `anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall` (task 01M737WW16) times out, run the package again.
- [x] Send the commit to testudoapp-75.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1