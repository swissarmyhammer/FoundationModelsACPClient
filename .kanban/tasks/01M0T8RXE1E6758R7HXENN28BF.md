---
comments:
- actor: claude-code
  id: 01m0tbmpxyqpkw3y2wj6wddpm5
  text: |-
    Picked up. Precondition check (task y418mzx on the FoundationModelsExtras board) is satisfied:

    - `git show origin/main:Sources/FoundationModelsExtras/ProcessRegistry.swift` on FoundationModelsExtras declares `public final class ProcessRegistry: Sendable` with `public init()`, `public func register(_:)`, `public func deregister(_:)`, `public var registeredPids`, `public func sweep(_:)` and `public static var global` behind the `atexit` installer.
    - `git show origin/main:Package.swift` declares `.library(name: "FoundationModelsExtras", targets: ["FoundationModelsExtras"])` and the same `.macOS("27.0")` floor this package states, so the two manifests resolve together.

    Research on this package:

    - The local copy is `Sources/FoundationModelsACPClient/ProcessRegistry.swift`. Only `AgentProcess.swift` uses it: `AgentProcessState(registry: .global)` in `AgentProcess.init`, `registry.register(pid)` in `record(pid:stdinWriteDescriptor:)`, and `registry.deregister(taken.pid)` in the teardown. `sweep(_:)` has no caller in this package outside the file's own `atexit` installer.
    - `rg` over the whole repository finds `ProcessRegistry` in those two source files only. No test in `Tests/` and no test in `IntegrationTests/` names the type, so the deletion breaks no test.
    - `Tests/FoundationModelsACPClientTests/ForbiddenImportTests.swift` holds `forbiddenModules = [FoundationModels, FoundationModelsACPAgent, FoundationModelsMCP, FoundationModelsRouter, SwiftUI]`. `FoundationModelsExtras` is not in that set and the scan compares the full module name, so the new import passes with no change to the test.
    - `Package.swift` also states "This is the only external dependency of this package" and "This library knows only the ACP wire and Observation". Both become false with this change, so both are rewritten beside the two source comments the card names.
    - `IntegrationTests/Package.swift` restates only the packages its own test target names a product of. That target names `FoundationModelsACPClient` and `FoundationModelsACP`, not `FoundationModelsExtras`, so it needs no new entry; SwiftPM resolves Extras through the path dependency on `..`.
  timestamp: 2026-08-24T17:03:43.550113+00:00
- actor: claude-code
  id: 01m0tbv67s6mc2shnnzmv8e0e3
  text: |-
    Implementation landed. Three files:

    - `Package.swift` — declares the `FoundationModelsExtras` package on `branch: "main"` over the SSH URL, beside the ACP wire, and gives its product to the library target and to the test target. The products comment said "This library knows only the ACP wire and Observation" and the dependency comment said "This is the only external dependency of this package". Both became false with this change, so both were rewritten beside the two source comments the card names.
    - `Sources/FoundationModelsACPClient/AgentProcess.swift` — `import FoundationModelsExtras` added, and the head comment rewritten. It now says the registry, its `sweep(_:)` and the `atexit`-installed `ProcessRegistry.global` come from `FoundationModelsExtras`, and that this package depends on the ACP wire and on that leaf. The text that names what this file still owns stays: the `posix_spawn` process-group spawn, the group kill, the reap, and the three teardown triggers.
    - `Sources/FoundationModelsACPClient/ProcessRegistry.swift` — deleted, 123 lines.

    Neither call site changed, and `ForbiddenImportTests.swift` is untouched.

    Verification, each acceptance criterion measured rather than assumed:

    - `Sources/FoundationModelsACPClient/ProcessRegistry.swift` — ABSENT.
    - `rg -n "ACP wire only" Sources` — no match.
    - `rg -l "ProcessRegistry" Sources` — `AgentProcess.swift` alone.
    - `rg -n "^import FoundationModelsExtras" Sources` — `AgentProcess.swift` alone.
    - No comment in `Sources/` claims this package holds a copy of the registry.
    - `swift package resolve` resolved Extras at `main (c713295)`, with Stencil 0.15.1, Yams 6.2.2, PathKit 1.0.1 and Spectre 0.10.1 arriving transitively. `Package.resolved` is gitignored here, so no lockfile change is committed.
    - `swift build` — Build complete, 0 warnings.
    - `swift test` — 68 tests in 1 suite passed, 0 failures, 0 warnings. `sourcesHoldNoForbiddenImport()` passes with the new import in place.
    - `swift build --package-path IntegrationTests --build-tests` — Build complete. The integration package needed no manifest edit: its test target names no Extras product, so SwiftPM resolves Extras through the path dependency on `..`.
    - `swift test --package-path IntegrationTests` — 4 tests passed, including `spawnedAgentLeavesNoStrayPidAfterTeardown()` and `agentChildProcessIsCleanedUpWithTheGroup()`. That is the real spawn/register/deregister/reap path against a spawned process, and the shared registry behaves the same there.

    One thing a person must decide, stated rather than done quietly:

    The dispatching instruction asked for `swift format -i -r Sources Tests` before finishing. That command was run, and it rewrote all 26 files under `Sources/` and `Tests/` — 3368 insertions and 3311 deletions — because this repository carries no `.swift-format` configuration and swift-format's default indent is 2 spaces where every file here is written with 4. `AgentProcess.swift` alone came back with 847 changed lines against the 14 this task needs. `.github/workflows/ci.yml` calls the shared `swift-ci.yaml`, and that workflow runs no format or lint step, so nothing in CI asks for the reformat. A repository-wide reindent is an unrelated refactor that would bury this task's diff, so the format run was reverted with `git checkout -- Sources Tests` and the two source edits were applied again. The diff is now 3 files, 30 insertions and 131 deletions. Whether this package should adopt a `.swift-format` and reindent is its own task for a person to open.
  timestamp: 2026-08-24T17:07:15.833565+00:00
- actor: claude-code
  id: 01m0tbvcdt1sksr5m7e4rs8sv9
  text: |-
    ### implement — changed
    - evidence: 3 files — /Users/wballard/github/swissarmyhammer/FoundationModelsACPClient/Package.swift, /Users/wballard/github/swissarmyhammer/FoundationModelsACPClient/Sources/FoundationModelsACPClient/AgentProcess.swift, /Users/wballard/github/swissarmyhammer/FoundationModelsACPClient/Sources/FoundationModelsACPClient/ProcessRegistry.swift (deleted). `swift build` clean with 0 warnings; `swift test` 68 tests passed; `swift test --package-path IntegrationTests` 4 tests passed. Every acceptance criterion measured.
    - next: /review. One open decision for a person: `swift format -i -r Sources Tests` reindents all 26 files of the repository (no `.swift-format` config, CI runs no format step), so it was reverted and the diff kept to this task.
  timestamp: 2026-08-24T17:07:22.170627+00:00
position_column: doing
position_ordinal: '80'
title: Use the shared ProcessRegistry from FoundationModelsExtras; delete the local copy
---
## What

`FoundationModelsExtras` gets a `public` `ProcessRegistry`. That is task
`y418mzx` on the `FoundationModelsExtras` board. This package holds one of four
copies of that type. Delete this copy and use the shared type.

Do this task only after `y418mzx` is done and is on the `main` branch of
`FoundationModelsExtras`. This package resolves that dependency from a branch.

The copy is `Sources/FoundationModelsACPClient/ProcessRegistry.swift`, 123
lines. Remove the comments and the blank lines, and it is identical to the MCP
copy. One file uses it:

- `Sources/FoundationModelsACPClient/AgentProcess.swift` —
  `registry.register(pid)`
- `Sources/FoundationModelsACPClient/AgentProcess.swift` —
  `registry.deregister(taken.pid)`

### 1. Add the dependency

`Package.swift` declares one dependency today: `FoundationModelsACP`. Add
Extras in the style the family uses:

```swift
.package(url: "git@github.com:swissarmyhammer/FoundationModelsExtras.git", branch: "main"),
```

Give the product to the library target and to the test target:

```swift
.product(name: "FoundationModelsExtras", package: "FoundationModelsExtras"),
```

This changes a rule that this package wrote for itself. The head comments of
`ProcessRegistry.swift` and `AgentProcess.swift` both say that this package
"depends on the ACP wire only". Change that text on purpose. Say that this
package depends on the ACP wire and on the family leaf
`FoundationModelsExtras`.

### 2. Delete the copy and import the shared type

- Delete `Sources/FoundationModelsACPClient/ProcessRegistry.swift`.
- Add `import FoundationModelsExtras` to
  `Sources/FoundationModelsACPClient/AgentProcess.swift`.
- The two call sites do not change. `register` and `deregister` keep their
  names and their shapes.
- The free function `sweep(_:)`, the private global, and the `atexit` installer
  go away with the file. The shared type owns them now.

There is one behavior change, and it is the purpose of this task. Today this
package installs an `atexit` sweep over a global registry of its own. After the
change, every consumer in the host process shares one registry and one sweep.

`Tests/FoundationModelsACPClientTests/ForbiddenImportTests.swift` scans
`Sources/` and fails on each import in its `forbiddenModules` set. That set
holds `FoundationModelsMCP`, `FoundationModelsRouter`, `SwiftUI`, and the other
names the library must not touch. `FoundationModelsExtras` is not in the set,
so the new import passes. Do not add it to the set.

### 3. Rewrite the comment at the head of `AgentProcess.swift`

The head comment of `AgentProcess.swift` says that this package holds its own
copy of the pattern, because the sibling types are internal to their packages.
That is no longer true. Say that the registry comes from
`FoundationModelsExtras`. Keep the text that describes what this package still
owns: the process-group spawn through `posix_spawn`, the group kill, the reap,
and the three teardown triggers.

## Acceptance Criteria

- [x] `Sources/FoundationModelsACPClient/ProcessRegistry.swift` does not exist.
- [x] `Package.swift` declares the `FoundationModelsExtras` package, and the
      library target and the test target both take its product.
- [x] `AgentProcess.swift` has `import FoundationModelsExtras`.
- [x] `rg -n "ACP wire only" Sources` finds nothing.
- [x] No comment says that this package holds a copy of the registry.
- [x] `rg -l "ProcessRegistry" Sources` names `AgentProcess.swift` only.

## Tests

- [x] `Tests/FoundationModelsACPClientTests/AgentProcessTests.swift` is the
      regression test for this task. It covers the spawn and the teardown. It
      must pass with no change to its assertions. That proves the shared
      registry behaves the same in the register, deregister, and reap path.
- [x] This package has no `ProcessRegistryTests` and must not get one. The five
      behavior tests of the type live in `FoundationModelsExtras` with the
      type.
- [x] `ForbiddenImportTests.swift` must pass unchanged. It proves the new
      import does not open a door to a module this library must not reach.
- [x] Run `swift package resolve` first, so the new dependency resolves.
- [x] Run `swift build`. It must succeed.
- [x] Run `swift test`. Every test must pass.

## Workflow

- Wait for task `y418mzx` on the `FoundationModelsExtras` board. This package
  cannot build until that type is `public` on `main`.
- `/tdd` does not apply. This task adds no behavior. It removes a duplicate.
  `AgentProcessTests` is the existing test that must stay green.