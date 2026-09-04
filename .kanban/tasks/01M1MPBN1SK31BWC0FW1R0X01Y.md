---
assignees:
- claude-code
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
position_column: todo
position_ordinal: '8380'
title: Resolve where the prompt comes from
---
## What

`cli-plan.md` §7 gives a four-row table for the prompt source. Implement it as
one testable value, apart from the command types, because the rows depend on
whether stdin is a terminal, and a test cannot make its own stdin a terminal.

Create `Sources/acp-client/PromptSource.swift`:

- `enum PromptSourceError: Error, Equatable { case noPromptAndStdinIsATerminal }`.
- `struct PromptSource: Sendable` with two injected members: an
  `isStandardInputATerminal: @Sendable () -> Bool` closure and a
  `readStandardInput: @Sendable () throws -> String` closure. The production
  values call `isatty(STDIN_FILENO) == 1` and read `FileHandle.standardInput`
  to end of file. A test injects both.
- `func prompt(from argument: String?) throws -> String`, implementing every
  row of §7:
  - an argument that is not `-`: use it;
  - `nil` and stdin is a pipe or a file: read stdin;
  - `nil` and stdin is a terminal: throw
    `noPromptAndStdinIsATerminal`, which the caller turns into the usage error
    and exit 2;
  - `"-"`: read stdin, a terminal included.

The agent's own stdin is a pipe that `AgentProcess` owns, and it is never this
binary's stdin. Write that as a comment on the type, so a later reader does not
try to share the descriptor.

## Acceptance Criteria

- [ ] Each of the four §7 rows behaves as the table says.
- [ ] The read of stdin is verbatim: no trimming, and no added or removed
      newline.
- [ ] `PromptSource` reads no global state at `init`, so a test never touches
      the real stdin.
- [ ] `RunCommand` maps `noPromptAndStdinIsATerminal` to the usage text on
      stderr and exit code 2, with stdout empty.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/PromptSourceTests.swift`, one
      test per §7 row, each constructing `PromptSource` with injected closures.
- [ ] One test asserts verbatim reading: the injected stdin gives
      `"a\n\nb\n"`, and the resolved prompt equals that string exactly.
- [ ] One test asserts the argument wins over stdin: with an argument given,
      the injected `readStandardInput` closure is never called.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.