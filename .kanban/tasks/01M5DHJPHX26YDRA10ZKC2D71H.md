---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5dhxvymezs5azvyt9x5cygt
  text: |-
    ### Research — cause of the warning

    1. The warning did not "come back". No change ever removed it. Card ^zws9qzt (01M3Z8M7YKRR5TQ5NRPZWS9QZT) closed with no change, because the user accepted the warning (its comment of 2026-10-04 and commit be7e615 "close task zws9qzt, because the MLX warnings are accepted"). From 2026-10-03, many step records show the warning as "accepted" in `swift build`, `swift test` and the integration build. `Package.resolved` is in `.gitignore`, so git has no history of it. `git log -S "missing creator"` finds only kanban commits. Thus, no dependency revision brought the warning back.

    2. The cause is the Swift Build engine. It is the default build system of Swift 6.4 (`swift build --help`: "swiftbuild - Swift Build build engine (default)"). A minimal package, with one C target that contains one `.metal` file and no other dependency, gives the same warning:
       `warning: missing creator for mutated node: ('.../.build/out/Products/Debug/metalrepro_CK.bundle/Contents/MacOS')`
       When the `.metal` file is replaced by a `.process("r.json")` resource, the warning does not occur. Thus, the trigger is a resource bundle that has a compiled `default.metallib`. Our own bundle (`Localizable.xcstrings`) does not cause the warning.

    3. The `Cmlx` target of mlx-swift 0.32.3 (revision 19601207) has `Source/Cmlx/mlx-generated/metal/*.metal`. These files make `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`, which MLX needs at run time. mlx-swift-lm (branch `stable`, d609e75) requires mlx-swift `.upToNextMinor(from: "0.32.3")`. Thus 0.32.3 is the only version that resolves, and each version has the Metal sources. A pin in this package cannot remove the warning.

    4. The only path to MLX in this graph is the core `FoundationModelsExtras` target (Extras dd3a078). It links `MLXLMCommon`, `MLXLLM`, `MLXEmbedders`, `MLXFoundationModels`, `MLXHuggingFace`, `HuggingFace` and `Tokenizers` for `ModelPool/MLXModelLoader.swift` and `ModelPool/ProgressReportingDownloader.swift`. FoundationModelsACP has no MLX dependency. `TelemetryTestSupport` depends on the core target, so the test target also gets MLX.

    5. `--build-system native` does not give the warning, but that flag is deprecated and prints its own warning. It is also a command flag, not a package change, and the shared CI does not use it.

    Current state (no change): `swift build` 1 warning; `swift test` 666 tests in 54 suites passed, 1 warning; `swift build --build-tests --package-path IntegrationTests` 1 warning. The warning is the same line in each run.
  timestamp: 2026-10-20T21:01:56.564168+00:00
- actor: claude-code
  id: 01m5dhy1jqcgsz5pvmc2d2zggp
  text: |-
    ### Blocker — the fix must go into another repository

    No change to `Package.swift` or `Package.resolved` of this package can remove the warning. One of these upstream changes is necessary:

    A. FoundationModelsExtras (recommended, the same fix that ^zws9qzt named): move `ModelPool/MLXModelLoader.swift` and `ModelPool/ProgressReportingDownloader.swift`, and the dependencies `MLXLMCommon`, `MLXLLM`, `MLXEmbedders`, `MLXFoundationModels`, `MLXHuggingFace` (mlx-swift-lm), `HuggingFace` (swift-huggingface) and `Tokenizers` (swift-transformers), out of the core `FoundationModelsExtras` target. Put them in a new target and library product (for example `MLXModelLoading`). Then the core `FoundationModelsExtras` target and `TelemetryTestSupport` do not link MLX. Consumers that use `ModelPool` with the built-in MLX loader (for example FoundationModelsRouter) must then add the new product. After that change, this package needs only a re-resolve (`swift package update FoundationModelsExtras`); its manifest does not change.

    B. swiftlang/swift-build (the root cause): report the bug with the minimal reproduction. A package with one C target and one `.metal` source file, built with `swift build` on Swift 6.4 (swiftlang-6.4.0.34.1), prints "missing creator for mutated node: ('.../<package>_<target>.bundle/Contents/MacOS')". A fixed Swift Build removes the warning with no change in any package of the family.

    Each of these changes is in another repository. This task does not change them.
  timestamp: 2026-10-20T21:02:02.327199+00:00
- actor: claude-code
  id: 01m5dhy85pzzcdg6e7b39k7avm
  text: |-
    ### implement — stuck
    - evidence: no file changed. `swift build`: 1 warning ("missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS"). `swift test`: 666 tests in 54 suites passed, the same 1 warning. `swift build --build-tests --package-path IntegrationTests`: complete, the same 1 warning. Minimal reproduction (one C target with one `.metal` file) gives the same warning, so the cause is Swift Build plus the Metal sources of mlx-swift Cmlx, which the core FoundationModelsExtras target brings in.
    - open: acceptance criterion 1 is answered (no revision brought it back; it was never removed, ^zws9qzt closed as accepted). Acceptance criterion 2 (zero warnings) is not met.
    - next: a person decides. Do change A in FoundationModelsExtras (move MLX to a separate product) or report B to swiftlang/swift-build, then re-resolve this package. Or accept the warning again and close this task.
  timestamp: 2026-10-20T21:02:09.078844+00:00
- actor: claude-code
  id: 01m5dhyna9yfmjerkzrnyd1931
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 0 files changed. The Swift Build engine (the default build system in Swift 6.4) gives this warning for each target that has `.metal` resources. The `Cmlx` target of mlx-swift 0.32.3 has them, and no pin in this package can remove them.
    - test: not run (no change)
    - commit: none
    - review: not run
    - next: a person must choose. A: move the MLX parts of FoundationModelsExtras into a separate product. B: report the bug to swiftlang/swift-build. C: accept the warning again and close this card.
  timestamp: 2026-10-20T21:02:22.537006+00:00
position_column: doing
position_ordinal: '80'
title: The SwiftPM warning "missing creator for mutated node" for mlx-swift_Cmlx.bundle came back
---
Found during ^jebhkm3.

`swift test` in the root package and `swift build --build-tests` in `IntegrationTests` show this line:

`warning: missing creator for mutated node: ('.../.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`

The card 01M3Z8M7YKRR5TQ5NRPZWS9QZT removed this warning before. It is in `done`, but the warning is in the build again. The cards ^yvrk73p and ^jebhkm3 record it too. No source file of this package causes it: the MLX bundle comes from a dependency (FoundationModelsExtras).

## Acceptance criteria
- [ ] Find which dependency revision brought the warning back.
- [ ] `swift build`, `swift test` and `swift build --build-tests --package-path IntegrationTests` show zero warnings.