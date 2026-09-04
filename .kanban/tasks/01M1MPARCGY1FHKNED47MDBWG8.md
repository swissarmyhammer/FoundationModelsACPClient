---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1p9x4yr794093j0zapg8pa2
  text: |-
    Research and two decisions the card could not foresee.

    1. `parseAsRoot([])` cannot return a `RunCommand`. Read
       `CommandParser.descendingParse` in the vendored swift-argument-parser:
       it falls back to the default subcommand and then calls
       `parsedCommand.validate()` on it. With an empty command line, `run`
       has no agent command, so `AgentInvocation.validate()` throws, exactly
       as §6 requires. The observed error proves the selection happened:

         CommandError(commandStack: [AcpClient, RunCommand],
           parserError: .noArguments(.userValidationError(
             "No agent command was given. ...")))

       So the test bullet is met by two tests instead of one:
       `runIsTheDefaultSubcommand` reads
       `AcpClient.configuration.defaultSubcommand` and parses
       `["--", "acp-agent", "acp"]` (no subcommand name) into a `RunCommand`;
       `anEmptyCommandLineIsAUsageError` pins the empty list at exit 2.

    2. ArgumentParser's own `exitCode(for:)` gives 64 (`EX_USAGE`) for a
       validation error, not the 2 that `cli-plan.md` §9 pins. Measured, not
       assumed. So ArgumentParser stays the classifier and a four-line
       `AcpClient.processExitCode(for:)` turns `.validationFailure` into
       `AcpClient.usageExitCode` (2) and passes every other class through
       unchanged. No competing exit-code enum: one constant and one
       function. `AcpClient.main()` stands in for ArgumentParser's own only
       to swap that number; the text is `fullMessage(for:)`, the same string
       `exit(withError:)` would have printed, still on stderr. Rows 3, 4, 5
       and 124 of §9 are left for ^9h4m0ev.

    Third note: the tests use `@testable import acp_client`, as
    `PromptSourceTests` already does. The command types are internal to the
    executable target, and making the whole tree public to satisfy a plain
    `import` would widen the surface of a binary no other module links.
    `AcpClientVersionTests` moved to the same import for the same reason,
    and its doc comment keeps the "never becomes main.swift" guard.
  timestamp: 2026-09-04T13:32:07.000923+00:00
- actor: claude-code
  id: 01m1pa7amsdwrh78zap4n2qj5m
  text: |-
    ### implement — changed
    - evidence: `swift test` — 100 tests in 5 suites passed, 0 failures,
      0 warnings on a fresh `swift build --build-tests`. Binary checked by
      hand: `--help` exit 0 to stdout; `--version` prints 0.1.0, exit 0;
      `acp-client run "hi"` with no `--` writes 0 bytes to stdout, the usage
      to stderr, and exits 2; `run "p" -- npx thing --model small` reaches
      the body and exits 1 with the not-implemented sentence.
    - files (9): Sources/acp-client/AcpClient.swift (edited),
      AgentInvocation.swift, SharedOptions.swift, RunCommand.swift,
      ProbeCommand.swift, DoctorCommand.swift,
      SubcommandNotImplementedError.swift (new),
      Tests/FoundationModelsACPClientTests/CommandParsingTests.swift (new),
      AcpClientVersionTests.swift (edited).
    - `SubcommandNotImplementedError` is the one type the three bodies throw
      until N2, N4 and N5 land. Each milestone deletes its own throw.
    - TDD order: the tests were written first and run first. The first run
      failed to compile on the five missing types; the second run failed on
      the two rows the comment above explains; the third run was green.
    - next: /review.
  timestamp: 2026-09-04T13:37:40.505344+00:00
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
position_column: doing
position_ordinal: '80'
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

- [x] `acp-client --help` prints the usage to stdout and exits 0.
- [x] `acp-client --version` prints `AcpClientVersion.current` to stdout and
      exits 0.
- [x] `acp-client run "hi"` with no `--` prints usage to stderr and exits 2,
      and writes nothing to stdout.
- [x] Everything after `--` reaches `agentCommand` unchanged, its own flags
      included, in the order given.
- [x] `acp-client probe` and `acp-client doctor` accept the same
      `-- <agent-command> [args...]` grammar as `run`.

## Tests

- [x] New `Tests/FoundationModelsACPClientTests/CommandParsingTests.swift`,
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
- [x] Extend `Tests/FoundationModelsACPClientTests/AcpClientVersionTests.swift`
      to assert `AcpClient.configuration.version == AcpClientVersion.current`.
- [x] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Notes from the implementation

Three bullets above were met in a shape the card could not foresee. Each is
recorded, with evidence, in the comment thread:

1. `parseAsRoot([])` cannot RETURN a `RunCommand`: ArgumentParser falls back
   to the default subcommand and then validates it, and `run` with no agent
   command is the §6 usage error. The bullet is met by
   `runIsTheDefaultSubcommand` (reads `configuration.defaultSubcommand`, and
   parses `["--", ...]` into a `RunCommand`) plus
   `anEmptyCommandLineIsAUsageError`.
2. `AcpClient.exitCode(for:)` is ArgumentParser's own and answers 64
   (`EX_USAGE`), not 2. It stays the classifier;
   `AcpClient.processExitCode(for:)` maps `.validationFailure` to
   `AcpClient.usageExitCode` (2). Rows 3, 4, 5 and 124 of §9 are left for
   ^9h4m0ev.
3. The tests use `@testable import acp_client`, as `PromptSourceTests`
   already does, because the command types are internal to the executable
   target.