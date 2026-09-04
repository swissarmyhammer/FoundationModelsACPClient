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
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
- 01M1MPARCGY1FHKNED47MDBWG8
position_column: doing
position_ordinal: '80'
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

- `wellBehavedAgent(answer:stopReason:)` — answers `initialize`, answers
  `session/new`, and on `session/prompt` sends the given text as
  `agent_message_chunk` updates and then a `state_update` carrying `idle` with
  the chosen stop reason. It writes ndJSON to stdout and nothing else.
- `bannerOnStdoutAgent()` — writes one non-JSON banner line to stdout before
  its first ndJSON message. This is the most common ACP defect (§10).
- `silentAgent()` — starts, reads its stdin, and never answers `initialize`.

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
- [ ] `wellBehavedAgent`, `bannerOnStdoutAgent` and `silentAgent` each spawn
      and behave as described, checked directly with `AgentProcess` rather
      than through `acp-client`.
- [ ] A hung agent fails the test inside `TransportTestDeadline.limit` rather
      than hanging the suite.
- [ ] No stub process outlives its test.

## Tests

- [ ] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/CLITestSupportTests.swift`.
      It asserts `acpClientBinaryURL()` gives an existing executable file, and
      that `runAcpClient(["--version"])` matches the acceptance row above.
- [ ] A test spawns `wellBehavedAgent` with `AgentProcess`, sends an
      `initialize` frame and a `session/new` frame, and asserts a well formed
      ndJSON answer comes back for each.
- [ ] A test spawns `bannerOnStdoutAgent` and asserts the first stdout line is
      not valid JSON, which is the condition the `doctor` check will find.
- [ ] A test spawns `silentAgent`, asserts no answer arrives inside a short
      limit, and asserts the pid is gone after teardown.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.