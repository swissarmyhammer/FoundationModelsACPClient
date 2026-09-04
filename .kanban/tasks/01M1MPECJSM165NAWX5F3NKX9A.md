---
assignees:
- claude-code
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
- 01M1MPARCGY1FHKNED47MDBWG8
position_column: todo
position_ordinal: '8880'
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