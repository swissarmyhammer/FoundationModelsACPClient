---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
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