---
position_column: todo
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
