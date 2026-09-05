---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rw4a41s9ds13j8t5h5sjes
  text: Research done. `rg -n -i 'an other' --glob '*.swift'` finds 17 hits in 16 files. All hits are in comments or doc comments. No hit is in a code identifier or a string literal. `CLITestSupport.swift` holds 2 hits. The same search over each file that is not Swift finds nothing. No hit is the phrase "the other" or "each other". No hit is a part of a different word, such as "than other" or "an otherwise". The validator rules for `.swift` files were read whole. No rule applies to a word change in a comment. No test is necessary because a comment change does not change behavior; the two test suites prove that the files still compile.
  timestamp: 2026-09-05T13:29:04.897107+00:00
- actor: claude-code
  id: 01m1rw7cw8qxvc4hz9xe8smvxd
  text: |-
    ### implement — changed
    - evidence: 17 replacements of "an other" with "another" in 16 Swift files. Each replacement is in a comment or a doc comment. No code identifier and no string literal changed. The files: `Package.swift`, `Sources/AcpClientCore/ProbeCommand.swift`, `Sources/AcpClientCore/AgentCommandDoctor.swift`, `Sources/AcpClientCore/RunCommand.swift`, `Tests/FoundationModelsACPClientTests/CoalescingTests.swift`, `Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift`, `IntegrationTests/Package.swift`, and under `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/`: `CLITestSupportTests.swift`, `RunCommandExitTests.swift`, `NoLeakedAgentTests.swift`, `StreamRulesTests.swift`, `TimeoutTests.swift`, `Support/StubAgents.swift`, `Support/CLITestSupport.swift` (2 replacements), `Support/TransportTestSupport.swift`, `Support/SectionNineExitCode.swift`. After the change, `rg -n -i 'an other' .` over the whole repository finds nothing and exits 1. `swift test` at the root: 223 tests in 19 suites passed, 0 failures, 0 warnings, 0 skipped. `swift test --package-path IntegrationTests`: 87 tests in 12 suites passed, 0 failures, 0 warnings, 0 skipped. The two acceptance boxes are ticked. No commit was made. The two modified `.kanban/tasks/01M1QGRNSBYDJWXTHG23ET20E2.*` files of the previous card were not touched.
    - next: `/review` moves the card to `review`.
  timestamp: 2026-09-05T13:30:46.024286+00:00
- actor: claude-code
  id: 01m1rwcnw661a20dn49cxqct7r
  text: |-
    ### test — green
    - evidence: `rg -n -i "an other" .` finds no match. `swift package clean && swift build`: build complete, no warning line. `swift test`: 223 tests in 19 suites, 0 failures, 0 warnings, 0 skipped. `swift build --package-path IntegrationTests` (after a fresh `.build` resolve): build complete, no warning line. `swift test --package-path IntegrationTests`: 87 tests in 12 suites, 0 failures, 0 warnings, 0 skipped.
    - next: both suites are green. No fix was needed.
  timestamp: 2026-09-05T13:33:39.078887+00:00
position_column: doing
position_ordinal: '80'
title: Replace "an other" with "another" in the Swift comments of both packages
---
## What

ASD-STE100 gives **another**. The words "an other" are not correct.

Card ^xbgsxs2 removed each "an other" from `cli-plan.md`. The same two words
stand in 15 Swift files, in doc comments and in file-header comments. Those
files are outside the scope of ^xbgsxs2, which touched the two Markdown
documents and two test files only, so the correction is this card.

## Where

Run this to get the current list:

```
rg -n "an other" --glob '*.swift'
```

At the time of writing it names files under `Sources/AcpClientCore/`,
`Tests/FoundationModelsACPClientTests/`, `IntegrationTests/`, and
`Package.swift`.

## Rules

- Change the words only. Do not change what a comment says.
- Do not touch a line that reads "the other" or "each other". Those are
  correct.
- `swift test` and `swift test --package-path IntegrationTests` must both stay
  green, because a doc comment change compiles.

## Acceptance Criteria

- [x] `rg -n "an other"` finds nothing in this repository.
- [x] Both test suites pass, with no warning.
