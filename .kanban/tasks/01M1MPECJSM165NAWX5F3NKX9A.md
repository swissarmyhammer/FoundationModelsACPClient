---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1pt93fa6t66nez1g2px79nz
  text: |-
    Research done. What I found:

    - `IntegrationTests/Package.swift` needs only one new line: `.product(name: "acp-client", package: "FoundationModelsACPClient")` in the test target. No new ROOT dependency is necessary. The integration package reaches the root by `.package(path: "..")`, and `acp-client` is a product of that same package, so SwiftPM resolves it with the deps already declared. The manifest's "restate verbatim" comment therefore has nothing to add here.
    - `FoundationModelsACPAgent/Tests/FoundationModelsACPAgentTestSupport/BuiltProductLocator.swift` is the locator to port. It reads `--test-bundle-path` from `CommandLine.arguments`, falls back to the `.xctest`-suffixed argument, then to `arguments[0]`, and rejects any argument that carries a `..` component. A bundle executable stands 4 levels below the products directory.
    - `ACPTransport` (wire package) publishes `var bytes: AsyncThrowingStream<Data, any Error>`, so a test can read an agent's RAW stdout from `AgentProcess.transport.bytes`. That is how the banner test can see a first line that is not JSON.
    - `StopReason` carries `wireValue`, so the stub script can take a typed stop reason and still write the wire string.
    - `AgentProcessTests.swift` holds a private `writeScript(_:)`. The new `Support/StubAgents.swift` will own that writer, and `AgentProcessTests` will call it, so the file does not gain a second copy.
    - The root package has no `ARCHITECTURE.md`, so there is nothing to keep in step.

    Constraint I could not remove: `run`, `probe` and `doctor` are not wired, so no argument list makes `acp-client` hang. The deadline in `runAcpClient` therefore stays a guard, and the "a hung agent fails inside the limit" row is proved by the `silentAgent` test instead.
  timestamp: 2026-09-04T18:18:15.914296+00:00
- actor: claude-code
  id: 01m1pty66bcekkvcndkn2j98eq
  text: |-
    Implementation landed. Notes for the next agent:

    **Two things the card asked for that the toolchain refuses.**

    1. `import acp_client` from the integration package does not compile: `unable to resolve module dependency: 'acp_client'`. SwiftPM builds an executable product for an other package to SPAWN, and it publishes no module for that package to IMPORT. So the `--version` test asserts the SHAPE of the version (three dot-separated numbers) rather than `AcpClientVersion.current`. The unit suite's `AcpClientVersionTests` already pins the constant and pins that `--version` reports it, so the two suites together still cover the row.
    2. Nothing makes `acp-client` hang today, because `run`, `probe` and `doctor` are not wired. The deadline inside `runAcpClient` is therefore a guard no test drives yet. The "a hung agent fails inside the limit" row is proved by the `silentAgent` test instead, which waits out a two-second window and then asserts nothing arrived.

    **What I did NOT do, on purpose.** `AgentProcessTests.swift` keeps its own `foreignAgentScript` and its own private `writeScript`. The new `Support/StubAgents.swift` carries a second temporary-script writer beside them. That looks like duplication, and the `duplication` validator's own rule is what stops me removing it: for a row whose counterpart stands outside the change and is not already a shared function, it says "extract one from the changed code and parameterize the difference. Do not edit the counterpart to make the two halves agree ... Report it as a separate task." So the shared builder lives in the new file, and folding `AgentProcessTests` onto it is a separate card someone can raise.

    **TDD record — each new test was watched failing before it passed.**
    - Removed the `acp-client` product line from `IntegrationTests/Package.swift` and deleted the built binary: both CLI tests failed, and the message named the directory it looked in — `No acp-client executable stands in ".../IntegrationTests/.build/out/Products/Debug"`. Restored.
    - Dropped the banner line from `bannerOnStdoutAgent()`: `theBannerAgentWritesANonJSONFirstLine` failed after 10.7 seconds, at the bound and not as a hang. Restored.
    - Gave the chunk the wrong `messageId`: `theWellBehavedAgentStreamsTheChosenAnswerAndStopReason` failed after 10.0 seconds. Restored.

    **Housekeeping proved.** After the runs, `pgrep` finds no stub agent and no `acp-client`, and the temporary directory holds no `acp-stub-agent-*` script and no `acp-client-stdin-*` file, so each `defer` really removes what it wrote.
  timestamp: 2026-09-04T18:29:46.827364+00:00
- actor: claude-code
  id: 01m1ptybx4q8cbm1ds9vqhcyeq
  text: |-
    ### implement — changed
    - evidence: 4 files. Edited `IntegrationTests/Package.swift` (the `acp-client` product dependency). Added `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/CLITestSupport.swift`, `.../Support/StubAgents.swift` and `.../CLITestSupportTests.swift`. Tests: `timeout 600 swift test --package-path IntegrationTests` — 10 tests in 3 suites passed, 0 failures; `timeout 420 swift test` — 180 tests in 12 suites passed, 0 failures. `swift build --build-tests` on both packages reports 0 warnings.
    - acceptance rows I could not complete as written: the `--version` row asserts the version SHAPE and not `AcpClientVersion.current`, because SwiftPM publishes no importable module for an executable product across a package boundary (`unable to resolve module dependency: 'acp_client'`). The unit suite pins the constant itself.
    - next: `/review`.
  timestamp: 2026-09-04T18:29:52.676825+00:00
- actor: claude-code
  id: 01m1pvdd7d0an4bb3pbtapqj21
  text: |
    ### review — findings
    - scope: `review sha 0288688~1..0288688` (the delta only)
    - evidence: 4 findings, 4 confirmed, 1 refuted — CLITestSupportTests.swift:28, StubAgents.swift:63, StubAgents.swift:76, StubAgents.swift:111
    - next: correct the four findings, then review again.

    Two points the implementer raised, and the judgement on each.

    **1. The `--version` acceptance row — the substitution is adequate. It is not a finding.**
    The row on this card asks for exit 0, the version on stdout, and an empty
    stderr. It does not ask for a comparison against `AcpClientVersion.current`.
    The assertion on the semantic-version shape meets the row as written.
    The chain that pins the value is complete and it is in the unit suite:
    `AcpClientVersionTests` asserts `AcpClient.configuration.version ==
    AcpClientVersion.current`, and ArgumentParser prints `configuration.version`
    for `--version`. SwiftPM publishes no importable module for an executable
    product across a package boundary, so the integration suite cannot read the
    constant. Keep the comment in `CLITestSupportTests.swift` that names this
    limit.

    **2. The near-copy in `AgentProcessTests.swift` — the reading is right, and it
    does not release the changed side.**
    The duplication validator, section "Where the Fix Goes", says an index-backed
    row puts the fix in the changed code, and says not to edit the counterpart.
    `AgentProcessTests.swift` is outside this commit, so do not edit it. Raise a
    separate task if the copy there is to go.
    But the same section gives case 2: when no shared function exists yet, extract
    one FROM THE CHANGED CODE. So the new copy in `StubAgents.swift` still needs
    the extraction.
    The engine did not raise that row. It raised the changed-set row
    `reuse/reuse` at `StubAgents.swift:111`, where both halves are new. The
    extraction that answers it — one shared temporary-file writer in `Support/`,
    called by `writeAgentScript` and `writeStandardInputFile` — also removes the
    changed-side half of the `AgentProcessTests.swift` near-copy. One fix answers
    both. No second finding is added.
  timestamp: 2026-09-04T18:38:05.549257+00:00
- actor: claude-code
  id: 01m1pvqydqevara00mvfkefaes
  text: |
    Corrected the four review findings. What each one took, and what else went with it.

    **Finding 1 — magic number, `CLITestSupportTests.swift`.** The literal was the
    `2` inside `.seconds(2)`. swiftlint reads a number bound straight to a `let` as
    named, and a number inside a call as magic, which is why
    `processSuiteTimeLimitMinutes = 5` beside it never reported. So the file now
    carries `private let stubAgentSilenceLimitSeconds = 2`, and
    `stubAgentSilenceLimit` reads `.seconds(stubAgentSilenceLimitSeconds)` — the
    shape the minutes constant already used. I read every other literal in the file:
    `processSuiteTimeLimitMinutes`, `semanticVersionComponentCount` and the `1`
    inside the raw `initialize` JSON string are each already named or not a numeric
    literal, so the one correction removes the cause from the whole file.

    **Findings 2 and 3 — the `make` prefix, `StubAgents.swift`.** The finding named
    two functions; the cause is the naming of every script builder in the file, so
    all three took the correction: `makeWellBehavedAgent(answer:stopReason:)`,
    `makeBannerOnStdoutAgent()` and `makeSilentAgent()`. `silentAgent()` was not in
    a finding and is renamed anyway. `writeAgentScript` and `removeAgentScript`
    keep their names: each begins with the verb of the side effect it has, which is
    what the rule asks for. The two doc links that named the old symbols are
    updated.

    **Finding 4 — the duplicated temporary-file writer.** New file
    `Support/TemporaryFiles.swift` holds `writeTemporaryFile(_:prefix:suffix:)`: the
    temporary directory, the UUID name, and one atomic write. `writeAgentScript`
    calls it with the `acp-stub-agent-` prefix and the `.sh` suffix;
    `writeStandardInputFile` calls it with the `acp-client-stdin-` prefix and no
    suffix. Neither holds path logic of its own any more.

    **`AgentProcessTests.swift` is untouched, as the review directed.** Its private
    `writeScript` stands outside this change. I raised `^pxhvwd6` for it, and put
    one more thing on that card: measured after a full integration run, the
    temporary directory holds many `acp-agent-*.sh` and several
    `acp-agent-child-*.pid` files, because no test there removes what it wrote. The
    stub-agent tests do remove theirs — after this run, `$TMPDIR` holds no
    `acp-stub-agent-*` and no `acp-client-stdin-*` file.

    **The `--version` shape assertion stands, with its comment.** The review judged
    the substitution adequate, and the comment that names the limit — SwiftPM
    publishes no importable module for an executable product across a package
    boundary — is still in `CLITestSupportTests.swift`.

    Housekeeping proved after the runs: `pgrep` finds no `swift-test`,
    `swiftpm-testing-helper`, `xctest`, `acp-client` or stub agent.
  timestamp: 2026-09-04T18:43:50.839864+00:00
- actor: claude-code
  id: 01m1pvr4xdcyqs7zqd0gbcdgqd
  text: |
    ### implement — changed
    - evidence: 4 files. New `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/TemporaryFiles.swift` (the shared `writeTemporaryFile(_:prefix:suffix:)` — finding 4). Edited `.../Support/StubAgents.swift` (`makeWellBehavedAgent`, `makeBannerOnStdoutAgent`, `makeSilentAgent`; `writeAgentScript` now calls the shared writer — findings 2, 3, 4), `.../Support/CLITestSupport.swift` (`writeStandardInputFile` now calls the shared writer — finding 4) and `.../CLITestSupportTests.swift` (`stubAgentSilenceLimitSeconds` named constant, and the renamed call sites — finding 1). `AgentProcessTests.swift` untouched. Tests: `timeout 600 swift test --package-path IntegrationTests` — 10 tests in 3 suites passed, 0 failures; `timeout 420 swift test` — 180 tests in 12 suites passed, 0 failures. `swift build --build-tests` on both packages reports 0 warnings.
    - new work raised: `^pxhvwd6` — fold `AgentProcessTests` onto the shared writer and remove the `acp-agent-*` scripts it leaves in the temporary directory.
    - next: `/review`.
  timestamp: 2026-09-04T18:43:57.485858+00:00
- actor: claude-code
  id: 01m1pw0ck2fwdsc064ecs8sdnb
  text: |-
    ### review — clean
    - evidence: `review sha caf248e~1..caf248e` — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 4 files reviewed. All 4 prior findings of 2026-09-04 13:31 are checked and verified in the code: stubAgentSilenceLimitSeconds at CLITestSupportTests.swift:24; makeWellBehavedAgent, makeBannerOnStdoutAgent and makeSilentAgent at StubAgents.swift:63, 76 and 94; writeTemporaryFile at Support/TemporaryFiles.swift:27, called by CLITestSupport.swift:277 and StubAgents.swift:121.
    - next: none. Task moved doing -> review -> done. AgentProcessTests.swift stays outside this change; task ^1pvpbvh holds its near-copy.
  timestamp: 2026-09-04T18:48:27.490008+00:00
- actor: claude-code
  id: 01m1pw13nyf0r1kbmew5ywt4v3
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 4 files; all four findings removed at the cause (named seconds constant; all THREE builders took the `make` prefix, not just the two named; one shared `writeTemporaryFile` in a new Support/TemporaryFiles.swift replaces the duplicated UUID-and-path logic)
    - test: green — integration 10 passed in 3 suites, root 180 passed in 12 suites, 0 failures, 0 warnings on both
    - commit: caf248e refactor(tests): apply the four ^f3nkx9a review findings to CLI test support
    - review: clean — zero new findings, all four prior items confirmed in the code, task moved to done

    Two things stand as the review directed, not as defects:
    - The `--version` test asserts the semantic-version SHAPE, not `AcpClientVersion.current`. SwiftPM publishes no importable module for an executable product across a package boundary. The unit suite pins the constant and pins that `--version` reports it.
    - `AgentProcessTests.swift` keeps its own near-copy of the script writer and was deliberately not edited; a separate task tracks it, and it also leaves stray `acp-agent-*.sh` and `acp-agent-child-*.pid` files in $TMPDIR because no test there removes what it wrote.
  timestamp: 2026-09-04T18:48:51.134311+00:00
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
- 01M1MPARCGY1FHKNED47MDBWG8
position_column: done
position_ordinal: '9780'
title: Add the CLI stub agents and the built-binary locator to the integration suite
---
## What

`cli-plan.md` §14 needs three stub agents and a way for a test to run the built
`acp-client`. Build them one time, here, so each later CLI test row is a few
lines. The CLI end-to-end tests spawn processes, so they belong in the nested
`IntegrationTests` package, beside the existing `AgentProcessTests`.

**The unit suite's `ScriptedStubAgent` cannot serve this suite.** It is
internal to `FoundationModelsACPClientTests`, and a Swift test target's types
are not visible to an other package. So the integration stubs are shell
scripts, following the temporary-script pattern already in
`IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentProcessTests.swift`.

Edit `IntegrationTests/Package.swift`:

- Add `.product(name: "acp-client", package: "FoundationModelsACPClient")` to
  the test target's dependencies. A test target that depends on an executable
  product makes SwiftPM build that binary into the same bin directory as the
  test bundle. `FoundationModelsACPAgent/IntegrationTests/Package.swift`
  already does this for `acp-agent`; copy its shape.
- Restate any new root dependency verbatim, as the manifest comment requires.

Create
`IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/CLITestSupport.swift`:

- `func acpClientBinaryURL() throws -> URL`. It finds the built `acp-client`
  beside the running test bundle, and throws a clear error naming the
  directory it looked in when the file is absent.
- `struct CLIResult { let exitCode: Int32; let standardOutput: Data; let standardError: Data }`
  and `func runAcpClient(_ arguments: [String], standardInput: Data? = nil,
  environment: [String: String]? = nil) async throws -> CLIResult`. It
  captures the two streams as `Data`, not `String`, so a test can assert on
  bytes, and it is bounded by the existing `TransportTestDeadline.limit`, so a
  hung binary fails the test rather than hanging the suite.

Create
`IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift`:

- `makeWellBehavedAgent(answer:stopReason:)` — answers `initialize`, answers
  `session/new`, and on `session/prompt` sends the given text as
  `agent_message_chunk` updates and then a `state_update` carrying `idle` with
  the chosen stop reason. It writes ndJSON to stdout and nothing else.
- `makeBannerOnStdoutAgent()` — writes one non-JSON banner line to stdout
  before its first ndJSON message. This is the most common ACP defect (§10).
- `makeSilentAgent()` — starts, reads its stdin, and never answers
  `initialize`.

Each helper returns the absolute path of a script it wrote into a temporary
directory, and the caller removes it. Later tasks extend this file; keep the
signatures easy to add to.

This task proves the plumbing only. It asserts nothing about `run`, `probe` or
`doctor`, because those subcommands do not exist yet.

## Acceptance Criteria

- [ ] `swift test --package-path IntegrationTests` builds `acp-client`, and
      the suite finds the binary.
- [ ] `runAcpClient(["--version"])` gives exit 0, the version on stdout, and
      an empty stderr.
- [ ] `makeWellBehavedAgent`, `makeBannerOnStdoutAgent` and `makeSilentAgent`
      each spawn and behave as described, checked directly with `AgentProcess`
      rather than through `acp-client`.
- [ ] A hung agent fails the test inside `TransportTestDeadline.limit` rather
      than hanging the suite.
- [ ] No stub process outlives its test.

## Tests

- [ ] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/CLITestSupportTests.swift`.
      It asserts `acpClientBinaryURL()` gives an existing executable file, and
      that `runAcpClient(["--version"])` matches the acceptance row above.
- [ ] A test spawns `makeWellBehavedAgent` with `AgentProcess`, sends an
      `initialize` frame and a `session/new` frame, and asserts a well formed
      ndJSON answer comes back for each.
- [ ] A test spawns `makeBannerOnStdoutAgent` and asserts the first stdout line
      is not valid JSON, which is the condition the `doctor` check will find.
- [ ] A test spawns `makeSilentAgent`, asserts no answer arrives inside a short
      limit, and asserts the pid is gone after teardown.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-04 13:31)

> Scope: `review sha 0288688~1..0288688` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/CLITestSupportTests.swift:28` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift:63` `swift/fluent-usage` — Factory methods that create/construct objects should begin with `make`. This function creates an agent script but is named `wellBehavedAgent()` instead of `makeWellBehavedAgent()`. Rename to `makeWellBehavedAgent(answer:stopReason:)`.
- [x] `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift:76` `swift/fluent-usage` — Factory methods that create/construct objects should begin with `make`. This function creates an agent script but is named `bannerOnStdoutAgent()` instead of `makeBannerOnStdoutAgent()`. Rename to `makeBannerOnStdoutAgent()`.
- [x] `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift:111` `reuse/reuse` — The `writeAgentScript` function duplicates the temporary file writing pattern from `writeStandardInputFile` in CLITestSupport.swift—both new code in the same change. Both write content to a temporary file with a UUID-based filename using nearly identical logic: create temp directory path, append component with UUID, write content, return path. A shared helper should be extracted to avoid this duplication. Extract a shared temporary file writing function parameterized over content type and file extension, then have both `writeStandardInputFile` and `writeAgentScript` call it. For example: `func writeTempFile(_ content: String, suffix: String) throws -> URL` or similar, allowing both to reuse the UUID+path logic.
