---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4rympbqqghzf5j32j8gkv44
  text: |-
    Research:
    - `IntegrationTests/Package.resolved` is ignored by `.gitignore` (`Package.resolved`). It is a local file only. Remove it; the resolve of the new package writes a new one.
    - The agent repo runs the agent in process with this library in `ClientInteropTests` (stub model) and composes a live agent with greedy decoding in `LiveAgent.makeHarness`: `Router(recordingsDir:loader: LiveModelLoader(), samplingMode: .greedy)` and `RoutedACPAgent(name:router:configuration:userDirectory:environment:)`. `ComposedAgent.compose` has no sampling mode parameter, so the test builds the router itself to get greedy decoding.
    - Each session of the agent loads its configuration again from the user layer, so the test writes a `config.yaml` into a temporary user directory (no skills marketplace, no code context), as `LiveAgent` does. This keeps the run offline after the model download.
    - Smallest generation model of the agent integration suites: `mlx-community/Qwen3-4B-4bit` (the shipped flash slot in `TierThreeFixture`). The embedding slot keeps its default `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`.
    - MLX: the agent repo uses `MetalLibraryTestBootstrap` of `FoundationModelsRouterTestSupport` so local `swift test` finds the shader library.
    - Risk: the agent depends on this package by URL, and the nested package depends on it by `path: ".."`. The two have one identity. Check how SwiftPM resolves this.
    - `SessionModel` applies updates from its stream on a separate task, so the transcript can lag behind the return of `prompt`. The test waits, with a deadline, for the agent message.
  timestamp: 2026-10-12T21:00:04.343427+00:00
- actor: claude-code
  id: 01m4rzxf07szyv95e127ztk0z7
  text: |-
    Implementation:
    - New `IntegrationTests/Package.swift` (path `..`, plus FoundationModelsACP, FoundationModelsACPAgent and FoundationModelsRouter by URL on `main`) and one test `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/LiveAgentTurnTests.swift`. The test runs `RoutedACPAgent` in process over `InMemoryTransport.pair()`, with `Router(loader: LiveModelLoader(), samplingMode: .greedy)`, and drives `ConnectionModel` / `SessionModel` through the public API only. Time limit 20 minutes.
    - `.github/workflows/ci.yml`: `integration-package-path: IntegrationTests`, `integration-no-parallel: true`, `integration-metallib-glob: "*Cmlx*/default.metallib"`, new header comment in the style of FoundationModelsKanban.
    - Removed the stale local `IntegrationTests/Package.resolved` (ignored by `.gitignore`); the resolve wrote a new one.

    What did not work:
    - `standard` and `flash` both `mlx-community/Qwen3-4B-4bit`: the router refuses it (`SameGenerationModelFailure`). The `flash` slot now names `mlx-community/Qwen3-1.7B-4bit`, the pair of the `agents-demo` example of FoundationModelsAgents.

    Discovery, and a decision:
    - SwiftPM writes "Conflicting identity for foundationmodelsacpclient": the agent depends on this package by URL, the nested package by path. SwiftPM uses the path (no checkout of the URL), so the test builds the local library. SwiftPM exempts only root packages (`allowedToOverride = root.manifests.values.contains(node.manifest)`). Each design with the agent package in the graph gives it, and the `acp-agent` executable has no greedy option. I asked the user; the answer was "figure it out". I kept the small in-process design, wrote the reason in the manifest comment, and opened ^e5wzcqx to remove the warning (options: upstream greedy option or package split, a helper package, or accept it).
  timestamp: 2026-10-12T21:22:20.295454+00:00
- actor: claude-code
  id: 01m4rzxhrdp8dtg45mh7yzwpya
  text: |-
    ### implement — changed
    - evidence: 3 files — IntegrationTests/Package.swift (new), IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/LiveAgentTurnTests.swift (new), .github/workflows/ci.yml; stale local IntegrationTests/Package.resolved removed. `swift test --package-path IntegrationTests`: 1 test in 1 suite passed (8.3 s); warnings: accepted MLX "missing creator" and the "Conflicting identity for foundationmodelsacpclient" warning (follow-up ^e5wzcqx). Root `swift test`: 533 tests in 41 suites passed; only the accepted MLX warning.
    - next: review. The acceptance criterion "after the push, the CI integration job runs and passes" needs a push, which this step does not do.
  timestamp: 2026-10-12T21:22:23.117168+00:00
- actor: claude-code
  id: 01m4s00ddw2vxna3w3grgmwzn5
  text: |-
    ### test - green
    - evidence: `swift test` at the root: 533 tests in 41 suites passed, 0 failed, 0 skipped. `swift test --package-path IntegrationTests`: 1 test in 1 suite passed (aConnectionModelRunsOneTurnAgainstARealAgent, real model).
    - warnings: only the known ones. The MLX "missing creator for mutated node" warning shows in both runs (accepted in ^zws9qzt). The SwiftPM "Conflicting identity for foundationmodelsacpclient" warning shows in the IntegrationTests run only (tracked in ^e5wzcqx). No other warnings.
    - next: none. No code changed.
  timestamp: 2026-10-12T21:23:56.988988+00:00
- actor: claude-code
  id: 01m4s0102evfapp6vyddg71fy3
  text: |-
    ### commit — changed
    - evidence: test(integration): add live-agent test and run it in CI (local commit, not pushed)
    - next: review
  timestamp: 2026-10-12T21:24:16.078442+00:00
position_column: doing
position_ordinal: '80'
title: 'CI: add one simple integration test in a nested IntegrationTests package, and always run it'
---
## Problem
CI never runs integration tests. The `unit / Integration (opt-in, real dependencies)` job is `skipped` on each run (for example run 38306818520 for 47eadc2). Commit 24643be deleted `IntegrationTests/Package.swift` and the `integration-package-path` input, and `.github/workflows/ci.yml` now says "there is no integration package". Only a stale `IntegrationTests/Package.resolved` is left. The sibling libraries (FoundationModelsACP, FoundationModelsExtras, FoundationModelsKanban, FoundationModelsACPAgent) all run integration on each push. The user requires the same here.

## Scope
The user asked for ONE simple integration test. Keep the package and the test small. Do not write a large suite.

## Contract
Obey `swissarmyhammer/workflows/docs/swift-ci.md` (local copy: `../workflows/docs/swift-ci.md`), Shape 2:
- `swift test` at the root runs only unit tests.
- The nested package `IntegrationTests/Package.swift` depends on the root package by `.package(path: "..")`. The root manifest does not name it.
- No environment variable selects a test.
- `ci.yml` gives `integration-package-path: IntegrationTests` to the shared `swift-ci.yaml`. Add `integration-no-parallel: true` if the test starts a process or loads a model. Add `integration-metallib-glob: "*Cmlx*/default.metallib"` if the graph includes MLX (FoundationModelsExtras does; see the Extras and Kanban `ci.yml`).
- Rewrite the header comment of `ci.yml` to describe this, in the same style as `../FoundationModelsKanban/.github/workflows/ci.yml`.

## The one test
One test, through the public API only (`import FoundationModelsACPClient`, no `@testable`), with a real agent:
1. `ConnectionModel.connect` to the agent, then `initialize`. Expect `state == .connected`.
2. `newSession`. Expect `openSessions.count == 1`.
3. `prompt` with a short text. Expect the `UserMessageEntry` `sendState` to be sent, and at least one `AgentMessageEntry` with text in `transcript`.
4. `disconnect()`. Expect `openSessions` to be empty and the model to be closed.

Give the test a `.timeLimit`.

Use `../FoundationModelsACPAgent` as the real agent. Its `IntegrationTests/Package.swift` shows how it depends on the sibling packages by `branch: main`, and how it handles MLX (`MetalLibraryTestBootstrap` in FoundationModelsRouter). Prefer the simplest approach that works: run the agent in process over an `InMemoryTransport` pair with its library product, or start its `acp-agent` executable through `AgentProcess` if the binary can be built for the nested package. Use the smallest real model that the agent repo uses in its own integration tests, with greedy decoding, so that each run gives the same result. Write the reason for the choice in the manifest comment.

## Do not
- Do not move the existing unit tests out of the root suite.
- Do not select tests with an environment variable.
- Do not add a busy state, a turn state, or an event stream.

## Acceptance criteria
- [ ] `IntegrationTests/Package.swift` exists and `swift test --package-path IntegrationTests` passes locally with one test.
- [ ] `swift test` at the root passes and runs no integration test.
- [ ] `ci.yml` gives `integration-package-path: IntegrationTests` and the correct other inputs, with an updated header comment.
- [ ] The stale `IntegrationTests/Package.resolved` is regenerated or removed as the new package needs.
- [ ] After the push, the CI integration job runs (not `skipped`) and passes.