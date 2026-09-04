---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1p8mx9vp6vkdxh3nc2jxv6f
  text: |-
    Picked up. Research notes:

    - `Sources/acp-client/` holds `AcpClient.swift` (`@main AsyncParsableCommand`) and `AcpClientVersion.swift` only. `RunCommand` does not exist yet; it belongs to ^7mdbwg8 (the subcommand tree). So the last acceptance row of this card, which asks that `RunCommand` map `noPromptAndStdinIsATerminal` to the usage text on stderr and exit code 2, cannot land here. This card implements `PromptSource` and its error in full.
    - Prevailing error pattern in this package: `AgentProcessError` is `public enum ... : Error, Equatable, CustomStringConvertible`, one doc comment per case, plus a `description` switch. `PromptSourceError` follows it.
    - Prevailing closure-injection pattern: `SwiftUIACPClient+Connect.swift` stores `@Sendable () -> Void` and takes `@escaping @Sendable` in `init`.
    - Prevailing test import: 13 test files use `@testable import <module>`. `AcpClientVersionTests.swift` uses a plain `import acp_client` on purpose, as the standing guard that `AcpClient.swift` never becomes `main.swift`. The new test file uses `@testable import acp_client`, so `PromptSource` stays internal to the executable target.
    - Prevailing test concurrency helper: `Mutex` from `Synchronization` (`CoalescingTests`, `SessionStateTests`).
    - `ForbiddenImportTests` scans all of `Sources/` recursively. `Darwin` and `Foundation` are permitted.
  timestamp: 2026-09-04T13:10:08.443383+00:00
- actor: claude-code
  id: 01m1p92p0j2q5byms4zmprecwz
  text: |-
    Implementation landed, TDD order kept.

    RED: wrote `PromptSourceTests.swift` first and ran `swift build --build-tests`. It failed with "cannot find 'PromptSource' in scope" and "cannot find 'PromptSourceError' in scope", which is the expected failure — the feature is missing, not a typing mistake.

    GREEN: wrote `Sources/acp-client/PromptSource.swift`. `swift test --filter PromptSourceTests` passes all six tests; the whole suite is 85 tests, zero failures, zero warnings.

    Shape of the value:
    - `PromptSourceError` is `Error, Equatable, CustomStringConvertible` with the one case `noPromptAndStdinIsATerminal`, matching the `AgentProcessError` pattern of this package.
    - `PromptSource` stores `isStandardInputATerminal: @Sendable () -> Bool` and `readStandardInput: @Sendable () throws -> String`. Each `init` default is a closure literal, so `init` only assigns and reads no global state. The production readings are `PromptSource.standardInputIsATerminal()` (`isatty(STDIN_FILENO) == 1`) and `PromptSource.readStandardInputToEndOfFile()` (`FileHandle.standardInput.readToEnd()`, decoded as UTF-8 and otherwise unchanged). `readToEnd()` was chosen over `readDataToEndOfFile()` because it throws, which the closure signature already carries, where the other raises an uncatchable ObjC exception.
    - Both declarations stay internal. The test file uses `@testable import acp_client`. The plain `import acp_client` of `AcpClientVersionTests` stays as it is, because that plain import is the standing guard that `AcpClient.swift` never becomes `main.swift`.
    - The agent-stdin warning of the card is the doc comment on the type: this binary's stdin and the agent's stdin are different descriptors, and neither may be pointed at the other.

    Tool gates run against the two new files, with the rosters the review validators state:
    - swiftlint (`force_unwrapping`, `force_try`, `force_cast`, `implicitly_unwrapped_optional`, `unused_optional_binding`, `unowned_variable_capture`, the three legacy rules, `no_magic_numbers`, `missing_docs`, `function_body_length`, `closure_body_length`, plus the `no_file_literal` and `no_direct_standard_out_logs` custom rules): 0 violations.
    - swiftformat --lint over the 23-rule idioms roster: 0/2 files require formatting.
    - periphery: nothing about the new code. Its one warning is a pre-existing unused import in `ScriptedStubAgent.swift`, which is a test file and out of the report scope of `dead-code-swift`.

    Duplication finding answered before review: the first draft repeated the same four-line `PromptSource(...)` construction in each of the six tests, differing only by two injected values, which is the "one function with an argument" shape. Extracted `PromptSourceTests.promptSource(standardInputIsATerminal:standardInput:)` and every test now calls it.

    Acceptance row NOT completed, and why: "RunCommand maps noPromptAndStdinIsATerminal to the usage text on stderr and exit code 2, with stdout empty." `RunCommand` does not exist yet — it belongs to ^7mdbwg8, the subcommand tree, and to ^0e160t, which wires RunCommand. Nothing was invented to stand in for it. The contract this card owes that later card is written into the doc comment on the error case: "The caller turns this into the usage text on stderr and exit code 2."
  timestamp: 2026-09-04T13:17:39.730096+00:00
- actor: claude-code
  id: 01m1p92td3f4ptjn0k35pdck7h
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/acp-client/PromptSource.swift (new), Tests/FoundationModelsACPClientTests/PromptSourceTests.swift (new). `swift test`: 85 tests in 4 suites passed, 0 failures, 0 warnings. Acceptance row not completed: "RunCommand maps noPromptAndStdinIsATerminal to the usage text on stderr and exit code 2, with stdout empty" — `RunCommand` does not exist yet and belongs to ^7mdbwg8 / ^0e160t.
    - next: /review
  timestamp: 2026-09-04T13:17:44.227498+00:00
- actor: claude-code
  id: 01m1p9a3nvawpb1gre0x70e12h
  text: |-
    ### review — clean
    - evidence: `review sha c2057dc~1..c2057dc` — zero new findings. counts: findings 0, confirmed 0, refuted 0, attempted 7, failed 0. Files reviewed: Sources/acp-client/PromptSource.swift, Tests/FoundationModelsACPClientTests/PromptSourceTests.swift. The four `.kanban/` files of the commit are excluded by `.reviewignore`. No prior `## Review Findings` section on the card, so nothing was open.
    - note: the acceptance row "RunCommand maps noPromptAndStdinIsATerminal to the usage text on stderr and exit code 2" stays unchecked on purpose. `RunCommand` does not exist yet; it belongs to ^7mdbwg8 and ^0e160t. No stand-in was invented. This is correct sequencing, and it does not hold this card back.
    - next: none — moved to done.
  timestamp: 2026-09-04T13:21:43.099302+00:00
- actor: claude-code
  id: 01m1p9ahh1fs1ms62830hgxns1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files (Sources/acp-client/PromptSource.swift, Tests/FoundationModelsACPClientTests/PromptSourceTests.swift)
    - test: green — `swift package clean && swift test`, 85 passed, 0 failed, 0 skipped, 0 warnings; `swift build --product acp-client` clean
    - commit: c2057dc feat(acp-client): add PromptSource for the §7 prompt-source table
    - review: clean — zero new findings, 7 validators, task moved to done

    One acceptance row was deliberately left unmet: "RunCommand maps noPromptAndStdinIsATerminal to the usage text on stderr and exit 2". `RunCommand` does not exist yet. That row is a contract ^7mdbwg8 (subcommand tree) and ^0e160t (wire RunCommand) owe, and it is recorded in the doc comment on the error case. No stand-in was invented.
  timestamp: 2026-09-04T13:21:57.281188+00:00
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
position_column: done
position_ordinal: 8d80
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