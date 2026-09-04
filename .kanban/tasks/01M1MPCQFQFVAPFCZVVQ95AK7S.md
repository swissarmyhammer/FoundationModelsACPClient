---
assignees:
- claude-code
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
position_column: todo
position_ordinal: '8580'
title: Build the stderr terminal layer on Noora
---
## What

`cli-plan.md` §5 and §8. The binary needs one place that owns every byte that
is not the answer text. The rule is absolute: this layer writes to **stderr**
only, and it draws nothing when stderr is not a terminal.

The family takes Noora directly, with no spike: the agent package's C1 spike is
cancelled by that decision, and `FoundationModelsACPAgent/cli-plan.md` §5.2 and
its milestone C1 need an update to say so. Raise that in the pull request; do
not edit the sibling repository from this task.

**Noora fights the stderr rule in three places. Each needs a deliberate
setting, and each gets an acceptance row.** Check every one against the
resolved checkout before writing code; the notes below come from reading
Noora's sources, not from its documentation.

1. **Noora writes to stdout by default.** `Noora.init` takes
   `standardPipelines: StandardPipelines = StandardPipelines()`, whose
   `output` is a `StandardOutputPipeline` built on `print`. Tables, prompts
   and the success path of the progress steps all go there. Build the instance
   as `Noora(standardPipelines: StandardPipelines(output: <the stderr
   pipeline>, error: <the stderr pipeline>))`, so both go to stderr.
2. **Noora has no free-standing spinner and no free-standing in-place line.**
   `Spinner` and `Spinning` are internal. The public surface is
   `progressStep(message:successMessage:errorMessage:showSpinner:renderer:task:)`,
   which hands the `task` closure an `@escaping @Sendable (String) -> Void`
   that rewrites the line in place, and which prints a success or error
   message when the task ends. So the API here is
   `withSpinner<T>(_ label: String, _ body: (@Sendable (String) -> Void) async
   throws -> T) async rethrows -> T`, and the caller reports the running tool
   name through the closure it is given. There is no separate
   `toolCallLine(_:)`. §8's "a plain spinner" means: choose the success and
   error messages so the run leaves no claim about what the agent was doing.
3. **Noora's own terminal gate reads the wrong descriptor.**
   `Terminal.isInteractive()` reads `STDIN_FILENO`, and `isColored()` reads
   stdout. §5 and §8 gate on **stderr**. With a piped prompt on stdin — a §7
   row — Noora would call itself non-interactive on a real terminal. Build
   `Terminal(isInteractive:isColored:)` from the injected
   `isStandardErrorATerminal` value instead.

Create `Sources/acp-client/TerminalOutput.swift`, **the only file in the
target that imports Noora**, so a later swap costs one file (§5):

- `enum TerminalVerbosity: Sendable { case quiet, normal, verbose }`, resolved
  from `--quiet` and `--verbose`. `--quiet` wins.
- `struct TerminalOutput: Sendable`, built with the verbosity, an injected
  `isStandardErrorATerminal: @Sendable () -> Bool`, and an injected sink
  `@Sendable (String) -> Void` that production points at stderr and a test
  points at a buffer.
- `func event(_ line: String)` — only at `.verbose`.
- `func error(_ line: String)` — at every verbosity, `.quiet` included, because
  §8 says `--quiet` writes nothing but errors.
- `withSpinner` as above. It runs `body` with no drawing at all when stderr is
  not a terminal or the verbosity is `.quiet`, and still passes it a
  line-update closure that does nothing.
- An `ACPLogger` bridge into `event(_:)`, so the connection's diagnostics never
  reach stdout.

## Acceptance Criteria

- [ ] `TerminalOutput.swift` is the only file under `Sources/acp-client/` that
      imports Noora.
- [ ] The `Noora` instance is built with both pipelines pointed at stderr.
- [ ] The `Terminal` value is built from the injected
      `isStandardErrorATerminal`, and not from Noora's own defaults, so a
      piped stdin does not turn the drawing off on a real terminal.
- [ ] With `isStandardErrorATerminal` false, `withSpinner` emits zero bytes,
      and `body` still runs, receives a working no-op line closure, and
      returns its value.
- [ ] At `.quiet`, `event(_:)` emits zero bytes in a terminal too, and
      `error(_:)` still emits. At `.normal`, `event(_:)` emits zero bytes.
- [ ] `--quiet` together with `--verbose` resolves to `.quiet`.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/TerminalOutputTests.swift`.
      Each test builds `TerminalOutput` over a buffer sink and a chosen
      `isStandardErrorATerminal` value, and asserts the exact bytes the buffer
      holds. One test per acceptance row above.
- [ ] One test walks `Sources/acp-client/` with the shared
      `swiftSourceFiles(under:)` helper and asserts exactly one file imports
      `Noora`. This is §5's single-import test.
- [ ] One test asserts `withSpinner` returns the body's value and rethrows the
      body's error, under both terminal states.
- [ ] The real proof that stdout stays clean is a file-descriptor test, and it
      belongs in the integration suite, not in a grep here: the `--frames`
      task asserts stdout holds the answer bytes only while a spinner runs.
      Note that dependency in this task, and do not write a grep that a
      Noora default would slip past.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.