---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1q6k4p4xzxvqz8f29a6xp6d
  text: |
    Research and decisions, for the next agent.

    **The RED was measured, not assumed.** The new integration test went in first, at HEAD, and `timeout 600 swift build --package-path IntegrationTests --build-tests` failed with `AcpClientCoreImportTests.swift:3:8 unable to resolve module dependency: 'AcpClientCore'` — the same shape the previous agent measured for `acp_client`. After the split the same command builds clean and the test passes.

    **Where `@main` landed, and why it is not where the card's words first read.** The card says `Sources/acp-client/` keeps "the `@main` entry point". That could not be `AcpClient.swift` unchanged. `AcpClient` names `RunCommand.self`, `ProbeCommand.self`, `DoctorCommand.self` and `AcpClientExitCode` in its body, so leaving it in the executable would have forced all four public — which is exactly "make the whole command tree public", and the card forbids that. `AcpClient` is also named from inside the library, by `ExitCode.swift` (`AcpClient.exitCode(for:)`) and `AgentSession.swift` (`AcpClient.commandName`), so it has to compile there anyway.

    So the root command moved to `Sources/AcpClientCore/AcpClient.swift`, and `Sources/acp-client/AcpClientMain.swift` holds a new four-line `@main struct AcpClientMain` that calls `AcpClient.main()`. That directory holds that one file and nothing else.

    **The whole widening is four declarations, all on `AcpClient`,** because the executable is the only caller outside the module: `public struct AcpClient`, `public init() {}`, `public static let configuration`, `public static func main()`. The last three are not a choice — Swift requires a public witness for each `ParsableCommand` requirement on a public conforming type. `RunCommand`, `ProbeCommand`, `DoctorCommand`, `TerminalOutput`, `AgentSession`, `AcpClientExitCode` and the rest all stay internal; the unit suite still reaches them with `@testable import AcpClientCore`. `AcpClientVersion` was already `public`, which is why the card could name it as the integration test's target.

    **The unit suite reads `@testable import AcpClientCore`, not a plain import.** It is in the same package, so `@testable` reaches internal and nothing had to be widened for it. Ten files changed the import line; five also changed a qualified `acp_client.TerminalOutput` to `AcpClientCore.TerminalOutput`, which those files spell in full because `FoundationModelsACP` exports a `TerminalOutput` of its own.

    **Three tests scan `Sources/acp-client` by path, and all three had to be retargeted.** They are the reason this move is not import-only:
    - `ExitCodeTests.noFileOutsideTheTableSpellsAnExitCodeNumber` requires `ExitCode.swift` to stand in the scanned directory.
    - `TerminalOutputTests.exactlyOneFileImportsNoora` requires exactly one Noora importer there.
    - `ManifestTests` reads `.executableTarget(name: "acp-client", dependencies: [...])` with a regex and pins the list at five entries.

    The first two now scan BOTH directories, through a new `RepositoryFile.commandLineClientDirectories` and `swiftSourceFiles(underAnyOf:)` in `SourceFiles.swift`. The union is exactly the old file set, so coverage is unchanged and neither rule can be evaded by moving a file into the thin executable. `ManifestTests` now reads `.target(name: "AcpClientCore", ...)`; the five-dependency count is unchanged, because that list moved wholesale to the library. `.target(` cannot match `.executableTarget(`, since that name carries no dot before its capital `T`.

    **The test target no longer depends on `acp-client`.** Nothing in `Tests/` names the shim, so the dependency would have been dead weight. `IntegrationTests/Package.swift` keeps its `acp-client` executable-product dependency — that is what makes SwiftPM build the binary beside the test bundle for `acpClientBinaryURL()` — and adds the `AcpClientCore` library product beside it.

    **Two facts `cli-plan.md` §3 and §5 asserted became false, so both were corrected.** §3 now carries a second table for `AcpClientCore` and states why the library must be a product. §5 named `Sources/acp-client/Terminal/TerminalRenderer.swift`, a path that never existed; it now names `Sources/AcpClientCore/TerminalOutput.swift`, the file the test actually pins.

    **Checks run beyond the two suites.** `periphery scan --retain-public --report-exclude 'Tests/**' --skip-build --index-store-path .build/out` reports "No unused code detected", so the new `AcpClientMain` is not orphaned and nothing was left behind by the move. Every one of the six `public` declarations across both source directories carries a doc comment. Both `swift build --build-tests` runs, root and integration, print zero warnings and zero errors.
  timestamp: 2026-09-04T21:53:27.748953+00:00
- actor: claude-code
  id: 01m1q6kawp2cmx13w2ty7qfw74
  text: |
    ### implement — changed
    - evidence: 22 files. Moved with `git mv` (16): every file of `Sources/acp-client/` into `Sources/AcpClientCore/`. New (2): `Sources/acp-client/AcpClientMain.swift` (the `@main` shim), `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AcpClientCoreImportTests.swift` (the boundary proof). Edited: `Package.swift`, `IntegrationTests/Package.swift`, `cli-plan.md`, and 14 files of `Tests/FoundationModelsACPClientTests/`. Tests: `timeout 420 swift test` — 199 tests in 14 suites passed, the same count as before the move. `timeout 600 swift test --package-path IntegrationTests` — 35 tests in 7 suites passed, the 34 that stood plus the new one. `swift build --build-tests` on both packages — zero warnings and zero errors. RED was measured first: the new test failed with `unable to resolve module dependency: 'AcpClientCore'` under the DEFAULT build system, and no `--build-system native` was used at any point.
    - next: /review
  timestamp: 2026-09-04T21:53:34.102529+00:00
position_column: doing
position_ordinal: '8180'
title: Split acp-client into a library target and a thin executable
---
## What

The four doctor cards cannot be built as they stand. They put the health
checks in `Sources/acp-client/`, the **executable** target, and test them from
the `IntegrationTests` package. SwiftPM publishes no importable module for an
executable product across a package boundary: `import acp_client` fails at
dependency scanning with `unable to resolve module dependency: 'acp_client'`
under the default `swiftbuild` build system, and
`IntegrationTests/.build/out/Products/Debug/` holds no `acp_client.swiftmodule`
at all. `--build-system native` does emit one, but it is deprecated and CI sets
no build-system input, so a suite that compiles only under `native` is a suite
CI cannot run.

The user chose the standard SwiftPM answer: make the executable thin, and put
everything it does in a library.

Do this:

- Add a library target `AcpClientCore` in `Package.swift`, with the
  dependencies `acp-client` has now (ArgumentParser, FoundationModelsACP,
  FoundationModelsACPClient, FoundationModelsExtras, Noora), and expose it as a
  package **product**, because the nested package can import only a product.
- Move every file now under `Sources/acp-client/` into `Sources/AcpClientCore/`
  EXCEPT the `@main` entry point.
- Leave `Sources/acp-client/` holding the `@main` type alone. It depends on
  `AcpClientCore` and calls into it. Nothing else lives there.
- Widen the access level of exactly what a caller outside the module needs.
  Prefer `public` on the seams a test drives; leave everything else internal.
  Do not make the whole command tree public.
- The root unit suite imports `AcpClientCore` in place of `@testable import
  acp_client`. Its existing tests must go on passing unchanged in behaviour.
- Add the `AcpClientCore` product to `IntegrationTests/Package.swift`.

This is a move, not a rewrite. No behaviour changes.

## Acceptance Criteria

- [x] `Sources/acp-client/` holds the `@main` entry point and nothing else.
- [x] `AcpClientCore` is a library product of the root package.
- [x] The root unit suite reaches every type it reached before, and its test
      count does not drop.
- [x] A file in the `IntegrationTests` package can `import AcpClientCore` and
      name a type from it, under the DEFAULT build system — no
      `--build-system native`.
- [x] `swift build` and `swift build --package-path IntegrationTests` report
      zero warnings.

## Tests

- [x] The existing root suite is the regression test for the move: run
      `swift test` and expect the same 199 tests in 14 suites, all passing.
- [x] Add one integration test that imports `AcpClientCore` and asserts on a
      type from it — `AcpClientVersion.current` matching the semantic-version
      shape is enough. This test is what proves the boundary the four doctor
      cards need, so it must fail before the split and pass after.
- [x] Run `swift test --package-path IntegrationTests` and expect the 34
      existing tests plus the new one, all passing.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
