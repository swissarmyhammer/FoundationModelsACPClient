---
assignees:
- claude-code
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
position_column: todo
position_ordinal: '8280'
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

- [ ] A bare name resolves to the first executable match in `PATH` order.
- [ ] A bare name with no match throws `notFoundOnPath`, and the error names
      every directory that was searched.
- [ ] A relative path such as `./agent` resolves against the process working
      directory, and the result starts with `/`.
- [ ] An absolute path is returned unchanged when it is an executable regular
      file.
- [ ] A path that exists but has no executable bit throws `notExecutable`; a
      directory throws `notARegularFile`; a missing path throws `noSuchFile`.
- [ ] Every value the resolver returns is accepted by
      `AgentProcess.init(command:arguments:)` without
      `commandNotAbsolute`.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/AgentCommandResolverTests.swift`.
      Each test builds a temporary directory tree with `FileManager`, writes
      files with chosen permission bits, and constructs the resolver over a
      `PATH` made of those directories. One test per acceptance row above.
- [ ] One test asserts `PATH` order: two directories both hold a file of the
      same name, and the resolver returns the one from the earlier entry.
- [ ] One test asserts an empty `PATH` throws `notFoundOnPath` with an empty
      searched list.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.