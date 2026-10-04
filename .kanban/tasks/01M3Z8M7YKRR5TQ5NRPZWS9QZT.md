---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m448wbnc9vnd3bfwjtbephez
  text: |-
    ### closed — not done
    The user accepted the MLX / mlx-swift SwiftPM warnings ("missing creator for mutated node" and the C++17 extension warnings), so this task is closed with no change. To remove the warning later, move MLX out of the core FoundationModelsExtras target, or use an mlx-swift version that does not cause it.
  timestamp: 2026-10-04T20:14:58.220541+00:00
position_column: done
position_ordinal: d180
title: Remove the SwiftPM "missing creator for mutated node" warning that the MLX bundle of FoundationModelsExtras main causes in `swift build`
---
## What
Since FoundationModelsExtras b22ba99 (2026-09-29), the `FoundationModelsExtras` library links `MLXLMCommon`, `MLXLLM`, `MLXEmbedders`, `MLXFoundationModels` and `MLXHuggingFace` from `swissarmyhammer/mlx-swift-lm`. This package takes `FoundationModelsExtras` from `main`, and `Package.resolved` is git-ignored, so CI and every fresh clone get MLX.

With Extras main 94c4d99, `swift build` at the root of this package prints:

`warning: missing creator for mutated node: ('<repo>/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`

A first build also prints C++ warnings from the mlx-swift checkout (`constexpr if is a C++17 extension`). `swift test` and `swift build --package-path IntegrationTests` do not print the SwiftPM warning. No source file of this package causes it.

Found during ^81s5j74: its acceptance criterion "swift build ... with no error and no warning" is not met only because of this warning.

- [ ] Decide where the fix goes: in FoundationModelsExtras (for example, move MLX to a separate product, so that a consumer of `FoundationModelsExtras` does not build MLX), or in this package.
- [ ] Make `swift build` at the root of this package complete with no warning.

## Acceptance Criteria
- [ ] `swift build` in this package prints no `missing creator for mutated node` warning and no warning from the mlx-swift checkout.

## Tests
- [ ] `swift build` and `swift test` pass with no warning. `swift test --package-path IntegrationTests` passes.