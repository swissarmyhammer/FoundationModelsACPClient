---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1p74n6bnw5m3s1m39nhp86k
  text: |
    Picked up. Research notes before the first edit:

    - Network is available. `tuist/Noora` newest tag is `0.57.0` (the repository is a monorepo, so it also carries `web-*` tags; only the bare semver tags are the Swift package).
    - Risk cleared before touching this package: a throwaway probe package with `platforms: [.macOS("27.0")]`, `swift-tools-version: 6.2` and `.upToNextMinor(from: "0.57.0")` on Noora builds clean in 8.5 s. So the "Noora CI runs on macOS 15 / Swift 6.1" risk the card names does not stop this task.
    - `Package.resolved` already pins `swift-argument-parser` at 1.8.2 through `FoundationModelsExtras`, so the direct `from: "1.8.0"` declaration adds no checkout, as `cli-plan.md` §4 says.
    - The forbidden-import scan in `ForbiddenImportTests` walks `Sources/` recursively from `#filePath`, so `Sources/acp-client/` enters the scan with no change to the walk itself — only the doc comment needs the correction.
  timestamp: 2026-09-04T12:43:47.275906+00:00
- actor: claude-code
  id: 01m1p80xvpbcmdjfxkavk1t4z9
  text: |
    Implementation landed, by `/tdd` in three red-green rounds.

    **Round 1 — the manifest.** Wrote `ManifestTests.swift` first: 6 tests, all 6 red for the right reasons (no `.executable(name: "acp-client"`, no `.executableTarget` block to parse, no Noora pin, no resolved entries). Then edited `Package.swift` and added `Sources/acp-client/AcpClient.swift`. All 6 green.

    **Round 2 — the importable target.** Wrote `AcpClientVersionTests.swift` with a plain `import acp_client`. Red with the exact failure the card names: `unable to resolve module dependency: 'acp_client'`. Then added `"acp-client"` to the test target, added `AcpClientVersion.swift`, and wired `version:` into the command configuration. Green.

    **Round 3 — the shared walker.** A refactor, so `sourcesHoldNoForbiddenImport` is the standing test; it stayed green through the move.

    **One deviation from the letter of the card, stated openly.** The card asks for `SourceFiles.swift` with `func swiftSourceFiles(under relativePath: String) throws -> [URL]`. The Swift `immutability` validator rule bans a top-level `func`: "A function belongs to a type. A top-level `func` carries no namespace ... DO: a `static func` on an `enum` namespace." So the helper is `static func swiftSourceFiles(under relativePath: String) throws -> [URL]` in an `extension RepositoryFile`, in the file the card names. The name, the argument label and the signature are all exactly what the card asks for, and the acceptance criterion holds: any file in the unit target calls `RepositoryFile.swiftSourceFiles(under: "Sources")`. A bare `SourceFiles` enum was rejected because `SourceFiles.swiftSourceFiles` stutters, which the `idioms` rule bans as well.

    That choice also removed a duplication the card did not ask about: `RepositoryFile` gained `url(relativePath:)`, which holds the `#filePath` walk to the repository root and the `..` path guard once. `read(relativePath:)` and `swiftSourceFiles(under:)` both call it, so a second copy of the root navigation never entered the target.

    **Second small change, also stated openly.** `forbiddenModules` in `ForbiddenImportTests.swift` went from `private` to internal, so `ManifestTests` reads the same five names from the other side of the boundary. The list itself is unchanged, as the card requires. The alternative was a second copy of the same five strings, which the `duplication` validator treats as a blocker.

    **Discovery for the next agent: `Package.resolved` is gitignored in this repository.** The test that reads it still holds, because SwiftPM resolves and writes the file before any build or test run, locally and in CI. But do not expect the file in a diff, and do not add it to one.

    **Risk the card named, and how it closed.** Noora resolves at `0.57.0`, and it builds against this package's macOS 27 / Swift 6.2 floor with no change to the floor, no vendoring and no substitution. Full `swift build --build-tests` is clean: 0 warnings.
  timestamp: 2026-09-04T12:59:13.654245+00:00
- actor: claude-code
  id: 01m1p8133s6aysb7vk44j4nk2s
  text: |
    ### implement — changed
    - evidence: 7 files — Package.swift; Sources/acp-client/AcpClient.swift (new); Sources/acp-client/AcpClientVersion.swift (new); Tests/FoundationModelsACPClientTests/ManifestTests.swift (new); Tests/FoundationModelsACPClientTests/AcpClientVersionTests.swift (new); Tests/FoundationModelsACPClientTests/SourceFiles.swift (new); Tests/FoundationModelsACPClientTests/ForbiddenImportTests.swift; Tests/FoundationModelsACPClientTests/RepositoryFile.swift. `swift build --build-tests` clean with 0 warnings; `swift test` 79 tests in 3 suites, 0 failures (72 before); `swift build --product acp-client` builds, and `.build/debug/acp-client --version` prints `0.1.0`.
    - next: `/review`
  timestamp: 2026-09-04T12:59:19.033732+00:00
- actor: claude-code
  id: 01m1p818j11akw5mf5my2hjn8s
  text: |
    Correction to the step record above: the count is 8 files, not 7. The list itself is complete and correct.
  timestamp: 2026-09-04T12:59:24.609822+00:00
- actor: claude-code
  id: 01m1p85p5dge0yyahhmgn8nkmg
  text: |-
    ### test — green
    - evidence: `swift package clean` then `swift test` — Build complete (14.30 sec), 79 tests in 3 suites passed, 0 failures, 0 skipped, 0 warnings. `swift build --product acp-client` — Build complete (0.81 sec), 0 warnings, 0 errors.
    - next: none
  timestamp: 2026-09-04T13:01:49.613021+00:00
- actor: claude-code
  id: 01m1p8f3qm8w6az3gp5s59vqqj
  text: |-
    ### review — clean
    - scope: `review sha b272400..af0d8fd` (commit af0d8fd, this iteration's checkpoint). `HEAD~1..HEAD` was stale: the kanban-only commit af878f2 landed after af0d8fd, so that range held only `.kanban/` files. The range was corrected to the parent of af0d8fd.
    - evidence: zero new findings. 8 files reviewed, 7 validators attempted, 0 failed, 0 skipped. Only `.kanban/` files excluded, by `.reviewignore`.
    - judged: `swiftSourceFiles(under:)` landed as a `static func` on `extension RepositoryFile` in Tests/FoundationModelsACPClientTests/SourceFiles.swift, because the Swift `immutability` validator forbids a top-level func. The name and the signature stay the same, and the helper is callable from every file in the unit test target. The acceptance criterion holds.
    - judged: `forbiddenModules` in ForbiddenImportTests.swift went from `private` to internal, so ManifestTests reads the one list. This is reuse, and it prevents the duplicate list the `duplication` validator looks for.
    - no prior `## Review Findings` section existed on this task, so nothing was carried over.
    - next: task moved review -> done.
  timestamp: 2026-09-04T13:06:58.420551+00:00
- actor: claude-code
  id: 01m1p8fp5tapgqhqrqwspvpa1g
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files; Noora resolved at 0.57.0 and built against the macOS 27 / Swift 6.2 floor, so the untested-upstream risk on the card is closed
    - test: green — `swift package clean && swift test`, 79 passed, 0 failed, 0 skipped, 0 warnings; `swift build --product acp-client` clean, `--version` prints 0.1.0
    - commit: af0d8fd feat(acp-client): declare the acp-client executable target, product, and dependencies
    - review: clean — zero new findings, 7 validators, task moved to done. Scoped to b272400..af0d8fd: a kanban-only commit af878f2 landed after the code commit, so HEAD~1..HEAD no longer named it.

    Carried forward: `Package.resolved` is gitignored in this repo, so the ManifestTests assertion that reads it holds locally and in CI (SwiftPM writes the file during resolution) but never appears in a diff.
  timestamp: 2026-09-04T13:07:17.306318+00:00
position_column: done
position_ordinal: 8c80
title: Declare the acp-client executable target, product and dependencies
---
## What

`cli-plan.md` §3 and §4 add one executable to this package. This task makes it
build and makes it reachable from an other package.

Edit `Package.swift`:

- Add two dependencies:
  - `apple/swift-argument-parser`, `from: "1.8.0"`. That is the floor
    `FoundationModelsExtras` uses, and the graph resolves it at 1.8.2 today,
    so it costs no new checkout.
  - `tuist/Noora`, the terminal design system §5 selects. Pin
    `.upToNextMinor(from: "<the version that resolves>")`, and **not**
    `from:`. Noora is a 0.x package, where `from:` accepts every future 0.x
    minor, and its release history holds breaking 0.x minors. Noora also
    pulls `onevcat/Rainbow`, `apple/swift-log` and `tuist/path` into this
    graph; name those three in the manifest comment, so the cost is visible.
    Noora's own CI runs on macOS 15 with Swift 6.1, so a macOS 27 build is
    untested upstream: if it fails, stop and report rather than working
    around it.
- Add `.executable(name: "acp-client", targets: ["acp-client"])` to
  `products`. It must be a product, and not a target alone:
  `FoundationModelsACPAgent` will depend on this package and spawn this binary
  from its own tests (§17), exactly as its own `IntegrationTests` package
  already does for `acp-agent`.
- Add `.executableTarget(name: "acp-client", ...)` at path
  `Sources/acp-client/`. Its dependencies are exactly **five**: the
  `FoundationModelsACPClient` target, and the `FoundationModelsACP`,
  `FoundationModelsExtras`, `ArgumentParser` and `Noora` products. §12 permits
  no more. `cli-plan.md` §3 lists four and omits `FoundationModelsExtras`,
  which contradicts its own §10: the `doctor` work needs `Doctorable`,
  `DoctorRunner`, `DoctorReport`, `HealthCheck`, `HealthStatus` and
  `PlainTextDoctorRenderer`. The documentation task corrects §3.
- Add the target `"acp-client"` to the dependencies of the
  `FoundationModelsACPClientTests` test target, so the unit suite can
  `import acp_client`.

Create `Sources/acp-client/AcpClient.swift`. The file must NOT be named
`main.swift`: a target with top-level code cannot be imported by a test
target. Declare `@main struct AcpClient: AsyncParsableCommand` with a
`configuration` that names the command and gives its abstract. The subcommand
tree belongs to the next task; this task needs only a body that builds.

Put the version in `Sources/acp-client/AcpClientVersion.swift`, a
`public enum AcpClientVersion { public static let current = "0.1.0" }`, so
`--version` and the tests read one constant.

Promote the source-file walker in
`Tests/FoundationModelsACPClientTests/ForbiddenImportTests.swift` to a shared
internal helper — a new `Tests/FoundationModelsACPClientTests/SourceFiles.swift`
with `func swiftSourceFiles(under relativePath: String) throws -> [URL]`. It is
`private` today, and three later tasks need to walk a source directory.
`RepositoryFile.read(relativePath:)` reads one file only, and is not a
substitute. Update the `ForbiddenImportTests` doc comment to say the scan now
covers the executable target too; do not change the forbidden list.

## Acceptance Criteria

- [ ] `swift build --product acp-client` produces a runnable binary.
- [ ] `Package.swift` declares the `acp-client` executable product.
- [ ] The `acp-client` target declares exactly five dependencies, and none of
      them is `FoundationModels`, `FoundationModelsACPAgent`,
      `FoundationModelsMCP`, `FoundationModelsRouter` or `SwiftUI`.
- [ ] The unit test target can `import acp_client`.
- [ ] `Package.resolved` holds `swift-argument-parser` and `Noora`, and the
      Noora requirement is `upToNextMinor`.
- [ ] `swiftSourceFiles(under:)` is callable from any file in the unit test
      target, and `ForbiddenImportTests` uses it.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/ManifestTests.swift`, reading
      `Package.swift` through `RepositoryFile.read(relativePath:)`. Assert:
      the file declares `.executable(name: "acp-client"`; the `acp-client`
      target block names `ArgumentParser`, `Noora` and
      `FoundationModelsExtras`; and the block names none of the five forbidden
      modules.
- [ ] One test reads `Package.resolved` and asserts it holds an entry for
      `noora` and one for `swift-argument-parser`.
- [ ] New `Tests/FoundationModelsACPClientTests/AcpClientVersionTests.swift`.
      It uses `import acp_client` and asserts `AcpClientVersion.current` is
      three dot-separated numbers. This test also proves the executable target
      is importable, which every later CLI unit test needs.
- [ ] `ForbiddenImportTests` still passes through the shared helper, with the
      new source directory in the scan.
- [ ] Run `swift test` and `swift build --product acp-client`. Both succeed.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.