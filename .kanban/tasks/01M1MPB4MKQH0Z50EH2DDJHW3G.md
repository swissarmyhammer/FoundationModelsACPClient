---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1pazphs9e3gd8eqw6wbz9mj
  text: |-
    Research notes, for the next agent.

    **`FileManager` is not `Sendable`.** A compile probe shows the SDK's
    `NSFileManager` has no `Sendable` conformance, so `struct AgentCommandResolver:
    Sendable` cannot hold one as a plain stored property. The property is
    `nonisolated(unsafe) private let fileManager: FileManager`, with a doc comment
    that says why the exception is safe: the resolver only reads, and it never
    assigns the delegate that makes a file manager unsafe to share. Do not try
    `@unchecked Sendable` on a `FileManager` subclass — it warns
    (`UnavailableSendableConformance`), because the superclass has an unavailable
    conformance.

    **How the working directory is faked in the test.** The working directory
    belongs to the process, so `FileManager.changeCurrentDirectoryPath` would
    change it for every test running beside it. `currentDirectoryPath` is
    overridable, so the test uses a `FileManager` subclass that returns the
    temporary tree. That is the reason the card asks for the file manager at
    `init` — it is the seam for the relative-path row, not only for the file
    checks.

    **Symbolic links.** Probed behaviour on this SDK:
    - `fileExists(atPath:)` follows links, so a dangling link reads as missing.
      That is what makes `noSuchFile` correct for a broken link.
    - `attributesOfItem(atPath:)` does **not** follow links; it reports
      `NSFileTypeSymbolicLink` for a link to a real binary. A `PATH` entry holding
      a link to the real binary is the ordinary case, so `isRegularFile(at:)`
      resolves the links first with `URL.resolvingSymlinksInPath()`.
    - `URL.resourceValues(forKeys: [.isRegularFileKey])` is also link-unaware, so
      it cannot replace the above.

    **A directory passes `isExecutableFile`.** A directory carries an executable
    bit of its own, so the regular-file check is what catches it, not the
    executable check. Removing the regular-file check makes
    "a directory throws notARegularFile" fail with "an error was expected but none
    was thrown" — that mutation was run, and it does fail.

    **An empty `PATH` entry is dropped.** POSIX reads an empty entry as the working
    directory. A working directory on `PATH` is how a command in a downloaded
    folder gets run by mistake, so the split uses
    `omittingEmptySubsequences: true`. This is also what makes the empty-`PATH` row
    give an empty searched list.

    **The `AgentProcess` acceptance row is asserted on the shape of the returned
    path, not on a construction.** `AgentProcess.init(command:arguments:)` spawns,
    and this package keeps every spawning test in the nested `IntegrationTests`
    package — `Tests/.../AgentProcessTests.swift` says so in its own header. The
    initializer applies exactly one test to the spelling of the command,
    `hasPrefix("/")`, so the unit assertion is that test, with a doc comment
    naming it.

    **Not wired into a subcommand yet.** The card asks for the resolver and its
    tests alone. `run`, `probe` and `doctor` call it in the tasks this one blocks
    (^24q3m8s, ^tzvb81, ^t3r24q3m8s / the doctor checks 1 and 2 card).
  timestamp: 2026-09-04T13:50:59.129717+00:00
- actor: claude-code
  id: 01m1pbbq4rhzbe4tjx2f450jhw
  text: |-
    Implementation landed, TDD order kept.

    RED: wrote `AgentCommandResolverTests.swift` first and ran `swift test`. It
    failed with "cannot find 'AgentCommandResolver' in scope" and "cannot find
    'AgentCommandResolutionFailure' in scope" — the feature missing, not a typing
    mistake.

    GREEN: wrote `Sources/acp-client/AgentCommandResolver.swift`. `swift test`:
    111 tests in 6 suites, zero failures, zero warnings.

    Mutation check, to prove the tests can fail. Two mutations were applied and
    then reverted:
    - `for directory in searchDirectories.reversed()` — "a bare name takes the
      earlier PATH entry" failed.
    - the regular-file check removed — "a directory throws notARegularFile" failed
      with "an error was expected but none was thrown".

    Shape of the value:
    - `AgentCommandResolutionFailure` is `Error, Equatable,
      CustomStringConvertible`, matching `AgentProcessError` and `PromptSourceError`
      in this package. Each `description` names the file or the name that failed,
      and `notExecutable` names the `chmod +x` that fixes it.
    - `resolve(_:)` is two flat halves: `resolveGivenPath(_:)` for a command
      holding a `/`, and `searchPath(for:)` for a bare name. Both go through one
      `failure(at:)` that returns the reason a path cannot be run, so the path
      branch throws it and the search branch skips on it. One implementation, two
      readings.
    - `init(path:fileManager:)` defaults `path` to `Self.environmentPath()`, the
      same shape `PromptSource` already uses for its two static defaults. That is
      the single place `run`, `probe` and `doctor` will read the process `PATH`
      from.
    - `searchDirectories` is `private`. The failure carries the list, so nothing
      outside needs the property.

    Tool gates run against the two new files, with the rosters the review
    validators state:
    - swiftlint (`force_unwrapping`, `force_try`, `force_cast`,
      `implicitly_unwrapped_optional`, `unused_optional_binding`,
      `unowned_variable_capture`, the three legacy rules, `no_magic_numbers`,
      `missing_docs`, `function_body_length`, `closure_body_length`, at the option
      values the rules state): 0 violations. The three custom rules
      (`no_unchecked_sendable`, `no_file_literal`, `no_direct_standard_out_logs`)
      have nothing to match: the file carries no `@unchecked Sendable`, no `#file`,
      and no `print`/`debugPrint`/`dump`.
    - swiftformat --lint over the idioms roster: 0/2 files require formatting.
    - periphery: nothing about the new code. Its one warning is the pre-existing
      unused import in `ScriptedStubAgent.swift`, the same one the `PromptSource`
      card recorded.

    One tool reading worth writing down, so the next agent does not repeat the
    work. Adding `--swift-version 6.2` to the swiftformat run turns on
    `swiftTestingTestCaseNames`, which then asks every `@Test("a display name")`
    plus camel-case function to become `@Test func \`a display name\`()`. That
    reading is wrong for this repo, for two reasons: the repository holds no
    `.swift-version` file, so the real run leaves those version-gated rules off;
    and `PromptSourceTests.swift`, which carries the same `@Test("...")` form, was
    reviewed clean by seven validators on ^1r0x01y. The new suite keeps the form
    every other test file in this package uses.

    Nothing was left undone. Every acceptance row and every test row of the card is
    ticked in the description.
  timestamp: 2026-09-04T13:57:32.952302+00:00
- actor: claude-code
  id: 01m1pbbtwk3t1yyqxcacqpdd16
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/acp-client/AgentCommandResolver.swift (new), Tests/FoundationModelsACPClientTests/AgentCommandResolverTests.swift (new). `swift test`: 111 tests in 6 suites passed, 0 failures, 0 warnings. `swift build --product acp-client`: clean. Every acceptance row and every test row of the card is complete; none was left undone.
    - next: /review
  timestamp: 2026-09-04T13:57:36.787017+00:00
- actor: claude-code
  id: 01m1pbm6r3p23gm9shspx5xmjd
  text: |-
    ### review — clean
    - scope: `review sha ce845ec~1..ce845ec` (diffs only; 2 files reviewed, 6 `.kanban/` files excluded by `.reviewignore`)
    - evidence: zero new findings — counts { findings: 0, confirmed: 0, refuted: 0, attempted: 7, failed: 0 }
    - prior acceptance and test rows: all checked; no earlier `## Review Findings` section to clear
    - the three recorded decisions are correct: `nonisolated(unsafe)` matches a read-only `FileManager` use with no delegate; `isRegularFile(at:)` must resolve links first because `attributesOfItem(atPath:)` reports the link; the shape assertion mirrors the real `guard command.hasPrefix("/")` in `AgentProcess.init`
    - next: none. Task moves to done.
  timestamp: 2026-09-04T14:02:11.075775+00:00
- actor: claude-code
  id: 01m1pbmsfxvy953mafgt6y7tz1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files (Sources/acp-client/AgentCommandResolver.swift, Tests/FoundationModelsACPClientTests/AgentCommandResolverTests.swift); all 12 rows met
    - test: green — `swift package clean && swift test`, 111 passed, 0 failed, 0 skipped, 0 warnings; `swift build --product acp-client` clean
    - commit: ce845ec feat(acp-client): resolve the agent command to an absolute executable path
    - review: clean — zero new findings, 7 validators, task moved to done
  timestamp: 2026-09-04T14:02:30.269653+00:00
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
position_column: done
position_ordinal: 8f80
title: Resolve the agent command to an absolute executable path
---
## What

`AgentProcess.init(command:arguments:)` throws
`AgentProcessError.commandNotAbsolute` for anything that does not start with
`/`. `cli-plan.md` §6 shows `acp-client probe -- npx @vendor/agent`, a bare
name. So the binary must do the `PATH` lookup that the library refuses to do,
and it must do it in one place that `run`, `probe` and `doctor` all share.
`doctor`'s first check (§10) reports the outcome of exactly this resolution.

Create `Sources/acp-client/AgentCommandResolver.swift`:

- `enum AgentCommandResolutionFailure: Error, Equatable`, with cases
  `notFoundOnPath(String, searchedDirectories: [String])`,
  `noSuchFile(String)`, `notExecutable(String)` and `notARegularFile(String)`.
  Each case carries what a person needs to fix the mistake.
- `struct AgentCommandResolver: Sendable`. It takes the `PATH` value and a
  `FileManager` at `init`, so a test drives it against a temporary directory
  tree and never against the machine's real `PATH`.
- `func resolve(_ command: String) throws -> String`. A command that holds a
  `/` is a path: make it absolute against the process working directory, then
  check it is a regular file and is executable. A bare name is searched through
  each `PATH` entry in order, and the first executable regular file wins. The
  return value is always an absolute path that `AgentProcess` accepts.

## Acceptance Criteria

- [x] A bare name resolves to the first executable match in `PATH` order.
- [x] A bare name with no match throws `notFoundOnPath`, and the error names
      every directory that was searched.
- [x] A relative path such as `./agent` resolves against the process working
      directory, and the result starts with `/`.
- [x] An absolute path is returned unchanged when it is an executable regular
      file.
- [x] A path that exists but has no executable bit throws `notExecutable`; a
      directory throws `notARegularFile`; a missing path throws `noSuchFile`.
- [x] Every value the resolver returns is accepted by
      `AgentProcess.init(command:arguments:)` without
      `commandNotAbsolute`.

## Tests

- [x] New `Tests/FoundationModelsACPClientTests/AgentCommandResolverTests.swift`.
      Each test builds a temporary directory tree with `FileManager`, writes
      files with chosen permission bits, and constructs the resolver over a
      `PATH` made of those directories. One test per acceptance row above.
- [x] One test asserts `PATH` order: two directories both hold a file of the
      same name, and the resolver returns the one from the earlier entry.
- [x] One test asserts an empty `PATH` throws `notFoundOnPath` with an empty
      searched list.
- [x] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.