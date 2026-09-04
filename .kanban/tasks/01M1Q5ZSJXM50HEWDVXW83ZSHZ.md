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
- actor: claude-code
  id: 01m1q74vnmnn13mygde64w4qpw
  text: |
    ### review — findings
    - scope: `review sha 5a4012d~1..5a4012d` (the diffs only), 53 files reviewed
    - engine counts: 0 findings, 0 confirmed, 1 refuted
    - evidence: 1 finding — Tests/FoundationModelsACPClientTests/ManifestTests.swift:161
    - the manifest regex now reads the `AcpClientCore` library target alone. It reads no `.executableTarget(name: "acp-client", ...)` block. The section 12 dependency cap, the required-product check and the forbidden-module check are all evadable through the thin executable target.
    - the other three checks passed: the move changed no behaviour (14 of 16 files byte-identical, 199 tests in 14 suites at both revisions); the `@main` shim reading is right (`RunCommand`, `ProbeCommand`, `DoctorCommand`, `AcpClientExitCode` all stay internal); the widening is 4 declarations on `AcpClient` alone, with no `@_exported` and no blanket `public`.
    - next: read the `acp-client` executable target block in `Package.swift` as well, and assert its dependency list holds `AcpClientCore` and nothing else. Then re-run the review.
  timestamp: 2026-09-04T22:03:08.340563+00:00
- actor: claude-code
  id: 01m1q75qdj9b45fymn9bz322te
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 22 files. All 16 files moved with `git mv` into the new `AcpClientCore` library target and product; `Sources/acp-client/` keeps only a four-line `@main` shim.
    - test: green — root 199 passed in 14 suites (count unchanged), integration 35 passed in 7 suites (34 + the new import proof), 0 warnings on both build-tests runs
    - commit: 5a4012d refactor(acp-client): split into AcpClientCore library and thin executable
    - review: findings — Tests/FoundationModelsACPClientTests/ManifestTests.swift:161

    The review confirmed three of the four points and refuted none of the work:
    - It is a move. 14 of the 16 files are byte-identical on both sides. Only `AcpClient.swift` and one comment in `TerminalOutput.swift` differ. Both revisions hold 199 tests in 14 suites, with identical per-file counts.
    - The `@main` shim reading is right. Keeping `AcpClient` in the executable would force `RunCommand`, `ProbeCommand`, `DoctorCommand` and `AcpClientExitCode` public, which the card forbids. All four are still internal.
    - The widening is contained to four declarations on `AcpClient`, and the module's whole public surface is six. One correction: `public init() {}` is a NEW declaration born public, not a widening of an existing one.

    The finding is a real hole the split opened. `ManifestTests` now reads the `AcpClientCore` target block alone, so the section 12 five-dependency cap, the required-product check and the forbidden-module check no longer see the `acp-client` executable target at all. A sixth package dependency, or a forbidden module, added to the thin executable passes every test today.
  timestamp: 2026-09-04T22:03:36.754535+00:00
- actor: claude-code
  id: 01m1q7b89r89a6g3zc166rnx2q
  text: |-
    Research for the review finding, before the edit.

    **The hole, read from the manifest.** `Package.swift` declares two targets for the command-line client: `.target(name: "AcpClientCore", dependencies: [...])` with the five entries §12 permits, and `.executableTarget(name: "acp-client", dependencies: ["AcpClientCore"])`. `ManifestTests.acpClientDependencies()` reads the first block only. Nothing reads the second.

    **Which rules of the file are one-sided, read one by one.**
    - `theManifestDeclaresTheExecutableProduct` — reads the whole manifest text for `.executable(name: "acp-client"`. Not one-sided.
    - `theTargetLinksEveryProductTheBinaryNeeds` — reads the library alone, and that is CORRECT. `cli-plan.md` §3 gives `AcpClientCore` the five links. If a person moved `Noora` down to the executable, the library-only subset check would fail, which is the wanted answer. Widening it to a union would weaken it, so it stays.
    - `theTargetDeclaresFiveDependencies` — the cap belongs on the library, for the same reason. It is capped end to end once the executable list is pinned to exactly one entry.
    - `theTargetNamesNoForbiddenModule` — genuinely one-sided. §12 bans the modules for the BINARY, and the binary is both targets. It must read both.
    - `theNooraRequirementIsUpToNextMinor` and `theResolvedFilePinsTheNewDependencies` — read `Package.swift` whole and `Package.resolved`. Not one-sided.

    `ForbiddenImportTests.sourcesHoldNoForbiddenImport` walks the whole of `Sources/` recursively, so the source half of the boundary already covers both directories. Only the manifest half was narrowed.

    **Why the helper becomes one runtime-built pattern instead of two literals.** A `Regex` is not `Sendable`, so the file cannot hold a stored pattern constant — the existing `theNooraRequirementIsUpToNextMinor` says so in a comment. Two literal patterns would mean two near-identical block readers. Instead `dependencies(ofTargetNamed:declaredBy:)` builds the pattern from the target name and the declaring function, so one code path reads both blocks and the entry-splitting is written once.

    `\.target\(` still cannot match `.executableTarget(`, because that name carries no dot before its capital `T`. That is what keeps the two readers apart.
  timestamp: 2026-09-04T22:06:37.880250+00:00
- actor: claude-code
  id: 01m1q7ts6b9bgzc1fvtpj58x3w
  text: |-
    The finding is fixed. What changed in `ManifestTests.swift`, and what was proven.

    **One reader for both target blocks.** `acpClientDependencies()` is gone. In its place stand `dependencies(ofTargetNamed:declaredBy:)`, which builds the block pattern from the target name and the declaring function (`target` or `executableTarget`) and so reads either block through one code path, and `dependencies(inList:)`, which splits one dependency list by entry form. Two one-line callers name the two targets: `clientTargetDependencies()` and `executableTargetDependencies()`. A `Regex` is not `Sendable`, so the pattern is built inside the function rather than stored, which is why the reader is parameterised instead of written twice.

    **The new rule.** `theExecutableTargetTakesTheLibraryAlone` asserts the `acp-client` executable target's dependency list holds exactly `["AcpClientCore"]` and no package product at all.

    **The rule that was one-sided is now two-sided.** `theTargetNamesNoForbiddenModule` became `neitherTargetNamesAForbiddenModule` and reads the union of both targets' names, through a new `TargetDependencies.allNames`. §12 bans those modules from the BINARY, and the binary is the library and the executable together.

    **The other two named rules stay on the library, and each now says why in a comment.** `theTargetLinksEveryProductTheBinaryNeeds` must fail if a required product moves down to the executable, so a union would WEAKEN it. `theTargetDeclaresFiveDependencies` counts where the dependencies stand; the new exact-list rule is what stops a sixth one hiding in the executable. Both readings are now stated at the call site.

    **No other rule of the file was one-sided.** `theManifestDeclaresTheExecutableProduct` and `theNooraRequirementIsUpToNextMinor` read the whole manifest text; `theResolvedFilePinsTheNewDependencies` reads `Package.resolved`.

    **The deliberate-failure check, run twice, both reverted.**
    1. Added `.product(name: "Noora", package: "Noora")` to the `acp-client` executable target. `theExecutableTargetTakesTheLibraryAlone` FAILED with `It names ["Noora"]`. Every other rule of the suite passed with the defect in place — which is exactly the hole the finding named. Removed; `git diff Package.swift` is now empty.
    2. Added `"AcpClientCore"` to `forbiddenModules` for one run. `neitherTargetNamesAForbiddenModule` FAILED with `They name ["AcpClientCore"]`. The library target does not name `AcpClientCore`; only the executable does, so that failure could only come from the newly-read side. Removed.

    **Rules read before the edit.** `dump validators` on the file returned 60 rules across code-hygiene, code-security, completeness, duplication, reuse, swift and test-integrity, and every one was read. The load-bearing ones here: `swift/optionals` forbids `guard` in a test, so the reader unwraps with `try #require`; `duplication/swift` carves out one-line forwarders to an already-extracted shared implementation, which is what the two named callers are; `test-integrity/no-test-cheating` bans a weakened assertion, and the forbidden-module assertion got stronger, not looser; `code-hygiene/magic-numbers-swift` is why the capture-group index is the named `dependencyListCapture` rather than a bare literal.
  timestamp: 2026-09-04T22:15:06.699579+00:00
- actor: claude-code
  id: 01m1q7tzjc3ke6twet3yvvd80z
  text: |
    ### implement — changed
    - evidence: 1 file — `Tests/FoundationModelsACPClientTests/ManifestTests.swift`. `Package.swift` and `ForbiddenImportTests.swift` were each edited for one deliberate-failure run and reverted; `git status` shows neither. Tests: `timeout 420 swift test` — 200 tests in 14 suites passed (199 plus the new rule). `timeout 600 swift test --package-path IntegrationTests` — 35 tests in 7 suites passed, unchanged. `swift build --build-tests` on both packages — 0 warnings. LSP diagnostics on the changed file — 0 errors, 0 warnings.
    - deliberate-failure check: run twice, each reverted. (1) A sixth dependency on the `acp-client` executable target made `theExecutableTargetTakesTheLibraryAlone` fail with `It names ["Noora"]`, while every other rule of the suite still passed — the hole the finding named. (2) `"AcpClientCore"` added to `forbiddenModules` made `neitherTargetNamesAForbiddenModule` fail with `They name ["AcpClientCore"]`; only the executable target names it, so that failure came from the newly-read side alone.
    - next: /review
  timestamp: 2026-09-04T22:15:13.228801+00:00
- actor: claude-code
  id: 01m1q8bd6mzt1dmh8s6dvmwcg8
  text: |
    ### review — findings

    - scope: `review sha b46d5f8~1..b46d5f8` (second pass). Engine: 0 findings, 1 file reviewed.
    - evidence: 1 finding from the scope checks — Tests/FoundationModelsACPClientTests/ManifestTests.swift:269
    - confirmed closed: the sixth-dependency case on the `acp-client` executable fails by execution (`swift test --filter ManifestTests` → `theExecutableTargetTakesTheLibraryAlone`: `dependencies.productNames.isEmpty` failed, "It names [Noora]"); the manifest was restored and the suite is 7 of 7 again. The forbidden-module case fails on both forms the prior finding named, as a product and as a bare string, and fails BOTH the new rule and the union rule.
    - confirmed one-sided by design: `theTargetLinksEveryProductTheBinaryNeeds` (a union would weaken it) and `theTargetDeclaresFiveDependencies` (its partner rule catches the executable-side evasion).
    - prior item `- [x]` checked.
    - still open: the shared splitter reads only `.product(name:package:)` and bare strings, so `.byName(name:)`, `.target(name:)` and `.product(name:package:condition:)` are invisible to the new rule.
    - next: read every `Target.Dependency` form in the splitter, then re-review.
  timestamp: 2026-09-04T22:24:11.476089+00:00
- actor: claude-code
  id: 01m1q8c8sm4h8bvt0g8na9vk28
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 1 file. One parameterised reader now serves both targets; a new rule asserts the `acp-client` executable takes `AcpClientCore` and no product; the forbidden-module rule reads the union of both targets.
    - test: green — root 200 passed in 14 suites (199 + the new rule), integration 35 passed in 7 suites, 0 warnings
    - commit: b46d5f8 test(manifest): assert acp-client target deps with a shared reader
    - review: findings — Tests/FoundationModelsACPClientTests/ManifestTests.swift:269

    The review proved the first hole is genuinely closed. It added a sixth dependency to the executable target, watched the new rule fail with `It names ["Noora"]`, and restored the manifest. It also confirmed the two rules that stay on the library alone are right to stay one-sided: a union would WEAKEN the required-product rule, because moving a link down to the executable must break the library's subset check.

    The new finding is the same evasion in a different dress. The shared splitter reads two of the five forms SwiftPM accepts for a `Target.Dependency`. `.byName(name:)`, `.target(name:)` and `.product(name:package:condition:)` are all invisible to it, so the same sixth dependency and the same forbidden module come straight back written another way, and the new rule's own premise — "and nothing else" — does not hold.
  timestamp: 2026-09-04T22:24:39.732019+00:00
- actor: claude-code
  id: 01m1q9ndsean4bhd1xdqb89q14
  text: |-
    The finding is fixed. The judgement the finding asked for, the change, and the proof.

    **`swift package dump-package` was measured, and it cannot work here.** The finding asked me to judge it rather than assume. Two measurements:

    1. While `swift test --filter ManifestTests` ran, a concurrent `swift package dump-package` blocked for the whole test run (slowest probe 3647 ms) and printed `Another instance of SwiftPM (PID: 3683) is already running using '.build', waiting until that process has finished execution...`.
    2. The direct test: a throwaway `@Test` that shells out to `timeout 45 swift package dump-package` from inside `swift test`. Result: `elapsed=45.013 status=124 bytes=0`, stderr `Another instance of SwiftPM (PID: 4712) is already running using '.build', waiting...`. Status 124 is the timeout kill.

    SwiftPM holds the `.build` lock for the whole of a `swift test` invocation, including test execution. So a `dump-package` child waits for the parent, and the parent waits for the child: a deadlock, not a slow call. The probe file was deleted. The JSON shape itself is good — `{"byName": [...]}`, `{"target": [...]}`, `{"product": [...]}` normalises every form — but it is unreachable from a unit test of this package. So the reader reads the text, and reads every form. That measurement is now recorded in the doc comment of `dependencies(ofTargetNamed:declaredBy:)`, where the next reader meets the question.

    **The hole was measured before the fix, once per form.** With the OLD reader, each of these was added to the `acp-client` executable target and `swift test --filter ManifestTests` still reported 7 of 7 passing: `.byName(name: "Noora")`; `.target(name: "FoundationModelsACPClient")`; `.product(name: "Noora", package: "Noora", condition: .when(platforms: [.macOS]))`. The finding was exact.

    **What replaced the two patterns.**
    - `entries(ofArrayAfter:in:)` reads the `dependencies:` array by nesting depth, in one pass, aware of string literals and `//` comments. This also closes a hole the finding did not name: the old block pattern `\[([^\]]*)\]` stopped at the FIRST `]`, so `condition: .when(platforms: [.macOS])` truncated the capture and every entry standing after such an entry was invisible.
    - `DependencyEntry` is an enum — `.module`, `.product(name:package:)`, `.unreadable` — and `dependencyEntry(readFrom:)` reads one entry into it. A bare string literal, `.byName(name:)` and `.target(name:)` all name a module directly, so they fold into `.module`; a `.product(...)` reads its `name:` and `package:` whatever trailing `moduleAliases:` or `condition:` follows.
    - **An entry in no known form is reported, never dropped.** `dependencies(ofTargetNamed:declaredBy:)` now fails through `try #require(declared.unreadableEntries.isEmpty, ...)`. A reader that silently dropped an unknown form would rebuild the same class of hole for the next form somebody writes.
    - `dependencies(inEntries:)` maps once and derives the four lists with `compactMap`, rather than appending into four `var` accumulators.

    **Two new tests lock every form permanently, so the guarantee no longer rests on a one-time manual mutation.** `theReaderReadsEveryDependencyForm` feeds a fixture manifest holding all five forms plus an entry after a bracket-carrying one plus a comment naming a module in quotes, and asserts the exact four lists. `theReaderReportsAnEntryNoFormReads` feeds an entry held in a constant and asserts it is reported and that the entry beside it survives.

    **The deliberate-failure results, each reverted.**
    | What was put in | What failed |
    |---|---|
    | `.byName(name: "Noora")` on the executable | `theExecutableTargetTakesTheLibraryAlone`: `It takes ["AcpClientCore", "Noora"]` |
    | `.target(name: "FoundationModelsACPClient")` on the executable | `theExecutableTargetTakesTheLibraryAlone`: `It takes ["AcpClientCore", "FoundationModelsACPClient"]` |
    | `.product(name: "Noora", package: "Noora", condition: .when(platforms: [.macOS]))` first in the executable list | `theExecutableTargetTakesTheLibraryAlone`: `It names ["Noora"]`. Only ONE issue was recorded, so `targetNames == ["AcpClientCore"]` still held — the entry standing after the bracket-carrying one was read, which is the truncation fix |
    | `.byName(name: "AcpClientCore")` on the executable, with `"AcpClientCore"` added to `forbiddenModules` | `neitherTargetNamesAForbiddenModule`: `They name ["AcpClientCore"]`. Only the executable names `AcpClientCore`, and only through a newly-read form, so the union rule reads the new forms |
    | `.target(name: "AcpClientCore")` on the executable, same forbidden list | `neitherTargetNamesAForbiddenModule`: `They name ["AcpClientCore"]` |
    | `dependencies: [coreDependency]`, a constant of type `Target.Dependency` | BOTH `theExecutableTargetTakesTheLibraryAlone` and `neitherTargetNamesAForbiddenModule`: `No form this reader knows reads ["coreDependency"] of the acp-client target` |

    The forbidden-module runs use a buildable stand-in because no name in `forbiddenModules` is a buildable dependency of this graph — `.target(name: "FoundationModelsMCP")` does not compile, so the manifest would never reach the rule.

    **The new tests were watched failing too.** With `dependencyEntry(readFrom:)` mutated to read bare strings and single-line products alone, `theReaderReadsEveryDependencyForm` failed on all four expectations and named the loss: `The reader read ["BareString", "AfterTheCondition"]` and `The reader read ["Product"]`. Reverted.

    **One measurement that changed my design reading.** My first mutation attempt — forcing `namePattern` to the bare-literal pattern — did NOT fail the tests. The bare-literal pattern `/"([^"]+)"/` matches the first quoted substring, and in every form SwiftPM accepts the first quoted substring IS the name, so the two patterns agree today. `quotedName` is kept because it reads the `name:` argument by name rather than by position, but a future agent should know the two are not independent, and should mutate the classification and not the pattern when testing this reader.

    **Rules read before the edit.** `dump validators` returned 60 rules over code-hygiene, code-security, completeness, duplication, reuse, swift and test-integrity. The load-bearing ones here: `reuse/reuse` is why the `dump-package` measurement is recorded in the code and not only on this card; `swift/immutability` ("Build a collection with `map`/`compactMap`, not a `var` accumulator") is why the classifier maps once instead of appending into four accumulators; `swift/state-modeling` ("Switches over domain enums are exhaustive — no `default:`") is why each `DependencyEntry` accessor lists every case; `code-hygiene/magic-numbers-swift` permits `0`, `1`, `-1` and `100`, and the scanner uses no other literal; `test-integrity/no-test-cheating` bans a weakened assertion, and every assertion here got stronger; `code-hygiene/dead-code` is why the now-unused `dependencyListCapture` constant was deleted with the capture group it named.
  timestamp: 2026-09-04T22:47:08.334529+00:00
- actor: claude-code
  id: 01m1q9nqx3mhm4zxhgpqctj78e
  text: |
    ### implement — changed
    - evidence: 1 file — `Tests/FoundationModelsACPClientTests/ManifestTests.swift`. `Package.swift` and `ForbiddenImportTests.swift` were each edited for deliberate-failure runs and reverted with `git checkout`; `git status` shows neither. Tests: `timeout 420 swift test` — 202 tests in 14 suites passed (200 plus the two new reader tests). `timeout 600 swift test --package-path IntegrationTests` — 35 tests in 7 suites passed, unchanged. `swift build --build-tests` on both packages — 0 warnings, 0 errors. LSP diagnostics on the changed file — 0 errors, 0 warnings.
    - dump-package judged, by measurement, not workable: a `dump-package` call from inside a test deadlocks on the `.build` lock the parent `swift test` holds — killed at 45 s, exit 124, 0 bytes, stderr `Another instance of SwiftPM (PID: 4712) is already running using '.build', waiting...`. The reader reads the manifest text instead, and reads every entry form. The measurement is recorded in the code.
    - deliberate-failure check, per form, each reverted: `.byName(name:)` → `It takes ["AcpClientCore", "Noora"]`; `.target(name:)` → `It takes ["AcpClientCore", "FoundationModelsACPClient"]`; `.product(name:package:condition:)` → `It names ["Noora"]` with the entry after it still read; the forbidden-module union rule failed on `.byName` and on `.target` alike with `They name ["AcpClientCore"]`; an entry in an unknown form failed both executable-reading rules with `No form this reader knows reads ["coreDependency"]`. Before the fix, all three forms passed 7 of 7.
    - also closed, unnamed by the finding: the old block pattern `\[([^\]]*)\]` truncated at the first `]`, so every entry after a `condition: .when(platforms: [.macOS])` was invisible.
    - next: /review
  timestamp: 2026-09-04T22:47:18.691156+00:00
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

## Review Findings (2026-09-04 16:55)

> Scope: `review sha 5a4012d~1..5a4012d` — the diffs only.
> The review engine reported 0 findings across 53 files.
> The item below comes from the four scope checks the review asked for.

- [x] `Tests/FoundationModelsACPClientTests/ManifestTests.swift:161` `scope-coverage/rule-not-evadable` — The regex matches only `.target(name: "AcpClientCore", dependencies: [...])`. It matches no `.executableTarget(name: "acp-client", ...)` block. Before this change the same regex read the `acp-client` executable target. Three rules now read the library target alone: the section 12 five-dependency cap (`theTargetDeclaresFiveDependencies`), the required-product check (`theTargetLinksEveryProductTheBinaryNeeds`), and the forbidden-module check (`theTargetNamesNoForbiddenModule`). A person can add a sixth package dependency, or a forbidden module, to the `acp-client` executable target, and no test fails. Read the `acp-client` executable target block as well, and assert that its dependency list holds `AcpClientCore` and nothing else.

### The other three checks passed

- A move, not a rewrite. 14 of the 16 moved files are byte-identical (R100, same blob hash on both sides). `AcpClient.swift` (R078) changes only doc comments, the removal of `@main`, a new `public init() {}`, and three `public` keywords; the bodies of `main()` and `processExitCode(for:)` are unchanged. `TerminalOutput.swift` (R098) changes one comment. The root suite holds 199 `@Test` and 14 `@Suite` at both revisions, with the same per-file counts across all 27 files. No behaviour changed.
- The `@main` shim reading is right. `Sources/acp-client/` holds one file, `AcpClientMain.swift`. Keeping `AcpClient` in the executable would make the executable name `RunCommand`, `ProbeCommand`, `DoctorCommand` and `AcpClientExitCode` across the module boundary, which makes all four public and breaks the "do not make the whole command tree public" rule. All four stay internal, proven by their R100 blobs. `AcpClientMain` is itself internal.
- The widening is contained. Every access-level change lands on `AcpClient`: `public struct` (line 22), `public init() {}` (line 27), `public static let configuration` (line 46), `public static func main()` (line 87). `init` and `configuration` are protocol witnesses `ParsableCommand` demands; `main()` is the seam the executable calls. `AcpClientVersion` and `AcpClientVersion.current` were already public before the move (R100). No `@_exported`, no `public extension`, no blanket `public`. 14 of the 16 moved files carry no access-level token at all.
- `ExitCodeTests` and `TerminalOutputTests` are clean. Both now read `RepositoryFile.commandLineClientDirectories` = `["Sources/AcpClientCore", "Sources/acp-client"]`. The new file set is a strict superset of the old: all 16 former files plus `AcpClientMain.swift`. Neither rule is evadable by putting a file in the thin executable.

## Review Findings (2026-09-04 17:16)

> Scope: `review sha b46d5f8~1..b46d5f8` — the diffs only.
> The review engine reported 0 findings across 1 file.
> The item below comes from the scope checks the review asked for.

- [x] `Tests/FoundationModelsACPClientTests/ManifestTests.swift:269` `scope-coverage/rule-not-evadable` — The shared splitter reads two of the five forms SwiftPM accepts for a `Target.Dependency`. `products` matches `.product(name:package:)` only, and `targets` matches a bare string only. It reads none of `.byName(name: "X")`, `.target(name: "X")`, and `.product(name:package:condition:)`, because the product pattern demands `)` straight after the package argument and the target pattern demands `^` or `,` straight before the quote. So `theExecutableTargetTakesTheLibraryAlone` sees an empty list where one of those three forms stands, and both of its expectations hold. A person can write `.byName(name: "Noora")`, `.target(name: "FoundationModelsMCP")`, or `.product(name: "FoundationModelsRouter", package: "FoundationModelsRouter", condition: .when(platforms: [.macOS]))` in the `acp-client` executable target, and no test fails — the sixth dependency and the forbidden module both come back in a new form. Read every entry of the list, not two forms of it: match the `name:` argument of `.byName(...)`, `.target(...)` and `.product(...)` alike, and end the product pattern at the `package:` argument rather than at `)`, so a trailing `condition:` still reads. The same splitter serves the library target, so the fix closes both.

### What the scope checks confirmed

- **The sixth-dependency case on the executable is closed, by execution.** With `.product(name: "Noora", package: "Noora")` added to the `acp-client` executable target, `swift test --filter ManifestTests` fails: `theExecutableTargetTakesTheLibraryAlone` records `Expectation failed: dependencies.productNames.isEmpty` — "It names ["Noora"]". The manifest was restored and the suite returns to 7 of 7 passing. The parameterised reader genuinely reads the `.executableTarget` block; it is not silently matching nothing.
- **The forbidden-module case is closed for both forms the prior finding named.** Replaying the reader against mutated manifest text: a forbidden module written as `.product(name: "FoundationModelsRouter", package: "FoundationModelsRouter")` fails BOTH `theExecutableTargetTakesTheLibraryAlone` and `neitherTargetNamesAForbiddenModule`; written as the bare string `"SwiftUI"` it fails both as well. The union is real — `neitherTargetNamesAForbiddenModule` reads the executable's names, not the library's alone. The gap is the entry form, recorded above, and not the union.
- **`theTargetLinksEveryProductTheBinaryNeeds` is right to stay one-sided.** It asserts `requiredProductNames` is a subset of the LIBRARY's products. One-sided is the strict reading: moving a required link down to the executable makes the library set incomplete and the rule fails. A union would accept that move and weaken the rule. Reading the library alone is what the comment claims, and the claim holds.
- **`theTargetDeclaresFiveDependencies` is right to stay one-sided, and its partner covers the gap.** The cap counts where the dependencies stand. The evasion it cannot see on its own — a sixth dependency hung on the thin executable — is what `theExecutableTargetTakesTheLibraryAlone` exists to catch, and that rule permits exactly one target name and zero products there. The pairing is complete for every entry form the splitter reads, so the finding above is the whole of what is left open.
- **The prior checklist item is checked.** The `## Review Findings (2026-09-04 16:55)` item on `ManifestTests.swift:161` carries `- [x]`, and the commit message records it as fixed.
