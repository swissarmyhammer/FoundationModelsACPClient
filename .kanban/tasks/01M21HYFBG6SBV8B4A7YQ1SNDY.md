---
comments:
- actor: claude-code
  id: 01m21jhd3jqjs9psh7qrcwqacf
  text: |-
    Picked up. Research result:

    - `--frames` is implemented in `Sources/AcpClientCore/FrameTeeTransport.swift`, and `RunCommand.sessionTransport(over:frames:terminal:)` wires it for `run` and `probe`. Unit tests: `FrameTeeTransportTests` and `RunCommandTransportTests`. Integration test: `StreamRulesTests.framesWritesEveryMessageToStandardError` proves both directions on stderr and the answer alone on stdout.
    - `probe` is implemented in `Sources/AcpClientCore/ProbeCommand.swift` and `ProbeReport.swift`. Unit tests: `ProbeReportTests`. Integration tests: `ProbeCommandTests` prove the report names each part, the transcript holds no `session/prompt`, and each probe stub exits 0.
    - One gap against the card: the acceptance row "`probe --json` decodes and equals the human form's values". The integration test `theJSONFormParsesAndThePlainFormIsNotJSON` only asserts that the four JSON members exist. No test decodes the JSON and compares its values with the human form.
    - The integration package can import `AcpClientCore` (its manifest names the product, and `AcpClientCoreImportTests` imports it), so a test can decode the binary's JSON into `ProbeReport` and compare `plainText()` with the plain run's stdout.

    Plan: add one integration test in `ProbeCommandTests` that decodes `probe --json` into `ProbeReport`, compares the decoded values with the stub agent's values, and compares the rendered plain text with the plain run's stdout. Then run both suites.
  timestamp: 2026-09-08T22:34:38.066766+00:00
- actor: claude-code
  id: 01m21jpvrqrwtw0wxxzdq2ft0p
  text: |-
    Implementation landed.

    What changed:
    - `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/ProbeCommandTests.swift`: one new test, `theJSONFormDecodesToTheValuesTheHumanFormPrints`. It runs `probe --json` and `probe` against the stub agent, decodes the JSON into `ProbeReport` through `@testable import AcpClientCore`, compares the decoded protocol version, authentication methods and slash commands with the stub agent's values, and compares `plainText()` plus the report terminator with the plain run's stdout. The file header now says why this file reads `AcpClientCore`, and a named constant carries the report terminator.
    - No production code changed. `--frames` and `probe` were already in place from the done cards "Tee every ndJSON message to stderr for --frames", "Wire --frames into run, and prove the two streams end to end", and "Implement probe: report what the agent supports, and run no turn".

    TDD record:
    - RED: with a temporary mutation of `ProbeSlashCommands.encode(to:)` that wrote the `listed` state as `reportedNone`, the new test failed with 2 issues (the decoded `slashCommands` and the rendered plain text). The mutation is removed; `git diff` shows no change under `Sources/`.
    - GREEN: the test passes with the mutation removed.

    Each card row and the test that holds it:
    - `--frames` on stderr, both directions, stdout clean: `StreamRulesTests.framesWritesEveryMessageToStandardError` (integration), `RunCommandTransportTests` and `FrameTeeTransportTests` (unit).
    - `probe` names each part: `ProbeCommandTests.theReportNamesEveryPartTheAgentReported`.
    - `probe` sends no `session/prompt`: `ProbeCommandTests.probeRunsNoTurnAndClosesItsSession` reads the transcript the stub agent wrote.
    - `probe --json` decodes and equals the human form: the new test.
    - `probe` exits 0 for an agent that answers `initialize`: every probe stub (two commands, empty list, no update) exits 0 in `ProbeCommandTests`.

    ### implement — changed
    - evidence: 1 file — /Users/wballard/github/swissarmyhammer/FoundationModelsACPClient/IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/ProbeCommandTests.swift. `swift test`: 227 tests in 20 suites passed, 0 warnings. `swift test --package-path IntegrationTests`: 92 tests in 13 suites passed, 0 warnings.
    - next: `/review`
  timestamp: 2026-09-08T22:37:36.919745+00:00
- actor: claude-code
  id: 01m21k105x779rzkf6ft6h0rax
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit b8343db). 0 findings. 7 validators ran, 0 failed. 1 file reviewed. 2 `.kanban/` files skipped by `.reviewignore`.
    - next: none. The task is in `done`.
  timestamp: 2026-09-08T22:43:09.117353+00:00
- actor: claude-code
  id: 01m21k1eqrs19xhez4nk20rrhd
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 1 file (IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/ProbeCommandTests.swift)
    - test: green — swift test 227 passed; swift test --package-path IntegrationTests 92 passed; 0 warnings
    - commit: b8343db
    - review: clean — 0 findings, task moved to done
  timestamp: 2026-09-08T22:43:24.024521+00:00
position_column: done
position_ordinal: af80
title: 'N3+N4: --frames and probe'
---
## What

Milestones **N3** and **N4** of this repository's `cli-plan.md`.

Asked for by `FoundationModelsACPAgent`, card `^p39z3bc`.

**N3 — `--frames`.** Write every ndJSON message to stderr, in both
directions, with a direction mark. This is the reason the binary
exists: it shows the protocol exchange, so a person can see what an
agent sent. stdout stays the answer text alone.

**N4 — `probe`.** Start the agent, initialize, and print what it
reports: the protocol version, the agent capabilities, the
authentication methods, and the slash commands. Run no turn. Its report
**is** its output, so it goes to stdout. `--json` prints the same report
as JSON. It exits 0 whenever the agent answers — the verdict belongs to
`doctor`, not here.

- [x] `--frames`, on stderr, both directions
- [x] `probe`, and its `--json` form
- [x] `probe` runs no turn

## Acceptance Criteria

- [x] `--frames` writes the messages to stderr, and stdout stays clean.
- [x] `probe` prints the stub agent's protocol version, capabilities,
      authentication methods and slash commands.
- [x] `probe` sends no `session/prompt`.
- [x] `probe --json` decodes to the same values as the human form.
- [x] `probe` exits 0 for any agent that answers `initialize`.

## Tests

- [x] `--frames` against the stub agent: the captured stderr holds both
      directions, and the captured stdout holds only the answer.
- [x] `probe` against the stub agent: the report names each field, and
      the recording client shows no `session/prompt` was sent.
- [x] `probe --json` decodes and equals the human form's values.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.