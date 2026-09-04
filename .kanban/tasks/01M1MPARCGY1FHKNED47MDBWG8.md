---
assignees:
- claude-code
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
position_column: todo
position_ordinal: '8180'
title: Build the acp-client subcommand tree, the -- separator and the usage errors
---
## What

`cli-plan.md` §6. Give the binary its command tree and its argument grammar.
This task adds no protocol work: each subcommand body may throw a
"not implemented" error that a later task replaces.

Create these files under `Sources/acp-client/`:

- `AcpClient.swift` (edit): give `@main struct AcpClient` a
  `configuration` with `subcommands: [RunCommand.self, ProbeCommand.self,
  DoctorCommand.self]` and `defaultSubcommand: RunCommand.self`, plus
  `version: AcpClientVersion.current` so ArgumentParser answers `--version`
  itself.
- `AgentInvocation.swift`: a `struct AgentInvocation: ParsableArguments` that
  every subcommand embeds with `@OptionGroup`. It holds
  `@Argument(parsing: .postTerminator) var agentCommand: [String]`, and it
  validates in `validate()` that `agentCommand` is not empty, throwing
  `ValidationError` when the `--` separator or the command after it is missing.
  The binary never splits a command string into words, so no quoting rule can
  go wrong.
- `SharedOptions.swift`: the §6.1 options as `ParsableArguments` groups —
  `--cwd <path>`, `--frames`, `--timeout <seconds>`, `--verbose`, `--quiet`,
  and `--json`. `--json` belongs to `probe` and `doctor` only, so it is not in
  the group `run` embeds.
- `RunCommand.swift`, `ProbeCommand.swift`, `DoctorCommand.swift`: the three
  `AsyncParsableCommand` types, each with its abstract from the §6 table, each
  embedding `AgentInvocation`.

`run` takes one optional `@Argument var prompt: String?` before the terminator.
There is no default agent: an empty `agentCommand` is always an error.

## Acceptance Criteria

- [ ] `acp-client --help` prints the usage to stdout and exits 0.
- [ ] `acp-client --version` prints `AcpClientVersion.current` to stdout and
      exits 0.
- [ ] `acp-client run "hi"` with no `--` prints usage to stderr and exits 2,
      and writes nothing to stdout.
- [ ] Everything after `--` reaches `agentCommand` unchanged, its own flags
      included, in the order given.
- [ ] `acp-client probe` and `acp-client doctor` accept the same
      `-- <agent-command> [args...]` grammar as `run`.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/CommandParsingTests.swift`,
      using `import acp_client` and ArgumentParser's in-process
      `parseAsRoot(_:)`. No process spawn. Assert:
      - `parseAsRoot([])` selects `RunCommand`, the default subcommand;
      - `parseAsRoot(["probe", "--", "a"])` selects `ProbeCommand` with
        `agentCommand == ["a"]`;
      - `parseAsRoot(["run", "p", "--", "npx", "x", "--model", "small"])`
        gives `prompt == "p"` and
        `agentCommand == ["npx", "x", "--model", "small"]`;
      - `parseAsRoot(["run", "p"])` throws, and
        `AcpClient.exitCode(for:)` for that error is 2;
      - `--cwd`, `--frames`, `--timeout`, `--verbose` and `--quiet` parse onto
        `run`, and `--json` parses onto `probe` and `doctor` but not onto
        `run`.
- [ ] Extend `Tests/FoundationModelsACPClientTests/AcpClientVersionTests.swift`
      to assert `AcpClient.configuration.version == AcpClientVersion.current`.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.