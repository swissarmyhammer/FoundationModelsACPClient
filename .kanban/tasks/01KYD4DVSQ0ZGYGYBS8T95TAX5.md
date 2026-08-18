---
comments:
- actor: claude-code
  id: 01m0abatpcnscsjshd1f5ssc0n
  text: |-
    Research results:

    - The repository is initialized. It has two commits and the remote origin git@github.com:swissarmyhammer/FoundationModelsACPClient.git. Thus the "git init" and "create the GitHub repo" items are already satisfied. No push is necessary or permitted in this step.
    - The package directory has no Package.swift, no Sources/, and no Tests/. The package is greenfield.
    - Family convention for an in-family pin (from FoundationModelsShelltool/Package.swift): `.package(url: "git@github.com:swissarmyhammer/FoundationModelsOperationTool.git", branch: "main")`. This task will pin FoundationModelsACP the same way.
    - Family CI convention (from FoundationModelsShelltool and FoundationModelsACP): a thin `.github/workflows/ci.yml` that calls the shared workflow `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main`. The shared workflow runs `swift build` and `swift test` on a self-hosted macOS runner.
    - Sibling manifests use swift-tools-version 6.1, 6.2, and 6.4. The local toolchain is Swift 6.4 (arm64-apple-macosx27.0). This package will use 6.2 with `platforms: [.macOS("27.0")]`, which matches FoundationModelsShelltool and FoundationModelsRouter.
    - FoundationModelsACP has `ProtocolVersion.v2` with rawValue 2 (Sources/FoundationModelsACP/Core/ProtocolVersion.swift). The smoke test will assert this fact through a constant in this package, so the linkage is real.
    - Plan: TDD. Step 1: manifest + empty source file + smoke test, watch the compile failure for the missing symbol. Step 2: implement the constant, watch green. Step 3: forbidden-import scanner test, then temporarily add `import SwiftUI` to a source file, watch the test fail, remove it, watch green.
  timestamp: 2026-08-18T11:50:28.812675+00:00
- actor: claude-code
  id: 01m0abfs7adtyv6y5b5v57jtwp
  text: |-
    Implementation complete, with TDD:

    1. RED 1: Package.swift + empty source file + LinkageSmokeTests.swift. `swift test` failed with "cannot find 'ACPClient' in scope" while FoundationModelsACP resolved and compiled. The failure was for the missing feature, not a typo.
    2. GREEN 1: Sources/FoundationModelsACPClient/ACPClient.swift declares `public enum ACPClient` with `supportedProtocolVersion: ProtocolVersion = .v2`. The smoke test passed.
    3. RED 2: ForbiddenImportTests.swift scans each Swift file below Sources/ for import statements of FoundationModels, FoundationModelsRouter, FoundationModelsACPAgent, FoundationModelsMCP, and SwiftUI. A temporary `import SwiftUI` in ACPClient.swift made the test fail with "ACPClient.swift: import SwiftUI". This satisfies the card item "verified to actually fail when a banned import is temporarily added".
    4. GREEN 2: the temporary import was removed. `swift build` and `swift test` pass: 2 tests, 0 failures, 0 warnings.

    Discovery that did not work at first: a file-scope `let` of type `Regex` does not compile under Swift 6 strict concurrency because `Regex` is not `Sendable`. The regex literal now lives inside the scan function.

    Notes on the acceptance criteria:
    - Package.swift declares exactly one dependency: FoundationModelsACP, pinned `branch: "main"` over the SSH URL, matching the family convention.
    - .github/workflows/ci.yml calls the shared workflow swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main, identical to FoundationModelsShelltool and FoundationModelsACP. The shared workflow runs `swift build` and `swift test` on macOS.
    - The repository was initialized before this task and has its initial commits and the GitHub remote. The new scaffold files stay uncommitted for the pipeline commit step.

    Files: Package.swift, .github/workflows/ci.yml, Sources/FoundationModelsACPClient/ACPClient.swift, Tests/FoundationModelsACPClientTests/LinkageSmokeTests.swift, Tests/FoundationModelsACPClientTests/ForbiddenImportTests.swift
  timestamp: 2026-08-18T11:53:11.146595+00:00
- actor: claude-code
  id: 01m0abfypfajwvbwva23baxa5k
  text: |-
    ### implement — changed
    - evidence: 5 files — Package.swift, .github/workflows/ci.yml, Sources/FoundationModelsACPClient/ACPClient.swift, Tests/FoundationModelsACPClientTests/LinkageSmokeTests.swift, Tests/FoundationModelsACPClientTests/ForbiddenImportTests.swift; `swift build` + `swift test`: 2 tests, 0 failures, 0 warnings
    - next: /review
  timestamp: 2026-08-18T11:53:16.751932+00:00
- actor: claude-code
  id: 01m0abhpyy6c6j8jydbybvp362
  text: |-
    ### test — green
    - evidence: swift build (clean rebuild) — build complete, 0 warnings; swift test — 2 tests run, 0 failures, 0 skipped
    - next: no action needed. Build and tests are clean.
  timestamp: 2026-08-18T11:54:14.366752+00:00
position_column: doing
position_ordinal: '80'
title: 'M0 Scaffold: SwiftPM package depending on the ACP wire only'
---
## What

`plan.md` -> **M0**. Greenfield package.

- `Package.swift`, swift-tools 6.x, `platforms: [.macOS("27.0")]` (family floor, no `@available` branching).
- **Exactly one external dependency: `FoundationModelsACP`**, pinned `branch: "main"` over the SSH URL, matching how every sibling in this family pins in-family packages (Router and ShellTool both do this for OperationTool). A version requirement would conflict for any app depending on both this and another in-family consumer.
- Library target `FoundationModelsACPClient`, test target using Swift Testing.
- **Assert the dependency boundary in code, not just prose:** no Router, no ACPAgent, no FoundationModelsMCP, no `FoundationModels` framework, and **no `import SwiftUI`** anywhere in `Sources/`. `Observation` only.
- CI workflow (macOS) running `swift build` + `swift test`, mirroring the family's shared workflow.
- `git init` + initial commit; create the GitHub repo under `swissarmyhammer` if that is the convention for a new family package.

## Acceptance Criteria

- [ ] `swift build` and `swift test` pass locally.
- [ ] `Package.swift` declares only `FoundationModelsACP`.
- [ ] A test asserts no forbidden imports appear in `Sources/` (Router / ACPAgent / MCP / FoundationModels / SwiftUI).
- [ ] CI workflow present and mirrors the local commands.
- [ ] Repo initialized and committed.

## Tests

- [ ] Smoke test: `@testable import FoundationModelsACPClient` plus `import FoundationModelsACP` compiles and asserts a trivial fact -- linkage is the real assertion.
- [ ] Forbidden-import scanner over `Sources/`, verified to actually fail when a banned import is temporarily added.

## Workflow

- Use `/tdd` -- write the failing smoke/boundary test first.
