---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1pmvycjzdkpn9he96ff4mqg
  text: |-
    Research done. Both wire facts on the card are verified against the resolved checkout:

    - `StopReason` in `.build/checkouts/FoundationModelsACP/Sources/FoundationModelsACP/Generated/Unions2.generated.swift` is `public enum StopReason: Codable, Hashable, Sendable` with SIX cases: `endTurn`, `maxTokens`, `maxTurnRequests`, `refusal`, `cancelled`, `unknown(String)`. It is not `CaseIterable`. So the test uses an explicit list of six values.
    - `IdleStateUpdate.stopReason` in `Models4.generated.swift` is `public var stopReason: StopReason?` and decodes with `forgivingDecodeIfPresent`. Optional confirmed.

    `cli-plan.md` §9 table read directly: 0, 1, 2, 3, 4, 5, 124, with the note that code 5 exists because the Rust doctor's code 2 for errors would collide with the usage error.

    `usageExitCode` overlap: `AcpClient.usageExitCode` is referenced from exactly one place, `AcpClient.processExitCode(for:)`, inside the same file. No test names it (`CommandParsingTests` keeps its own private expected value and asserts through `processExitCode`). So the constant moves into `ExitCode.swift` as `AcpClientExitCode.usage`, and `AcpClient.swift` reads `AcpClientExitCode.usage.rawValue`. No exception is needed for the "no bare numeric exit literal outside ExitCode.swift" row.

    `AgentProcessError.agentUnavailable` lives in `Sources/FoundationModelsACPClient/AgentProcess.swift` and is public, so `forError` can be tested against it.
  timestamp: 2026-09-04T16:43:41.842886+00:00
- actor: claude-code
  id: 01m1pnqwb23jyk87ceyjs5ap4n
  text: |-
    Implementation landed, TDD order kept.

    RED: `ExitCodeTests.swift` was written first. The run failed to build with `cannot find 'AcpClientExitCode' in scope` and `cannot find 'AcpClientTimeout' in scope`, and nothing else.

    GREEN, step 1: `ExitCode.swift` was added. Seven tests passed, and the source scan failed with exactly one line — `["AcpClient.swift:21"]`, the old `static let usageExitCode: Int32 = 2`. That is the observed red of the scan test, on the real defect.

    GREEN, step 2: `AcpClient.usageExitCode` was deleted and `processExitCode(for:)` now returns `AcpClientExitCode.usage.rawValue`. All 161 tests pass.

    How the `usageExitCode` overlap was resolved: the constant MOVED into `ExitCode.swift` as the `usage` case, with its "EX_USAGE is 64, section 9 pins 2" note carried onto the case. No exception is named for the acceptance row, because none is needed. The move was safe: `get callgraph` (inbound) and a repository-wide grep each showed one reader, `AcpClient.processExitCode(for:)`, in the same file. `CommandParsingTests` keeps its own private expected value and asserts through `processExitCode`, so it never named the constant. `processExitCode(for:)` keeps its own contract — ArgumentParser still classifies, and a clean exit such as `--help` still gets ArgumentParser's own number — because that is the parser's half of the table and `forError(_:)` is the run's half.

    How the bare-literal scan reads a file, and what it cannot read: comments and string literals are taken out first with one regex, each removed run leaving its line breaks behind so line numbers survive. This matters — section 9 is quoted in doc comments all over the target, and "and exits 2" is documentation. What remains is read a line at a time: a line that mentions an exit AND spells a decimal number at word boundaries. The word boundaries are what keep the `32` inside `Int32` from reading as a literal; without them `static func processExitCode(for error: any Error) -> Int32` would be a false positive. The scan reads decimal literals only, so a hexadecimal spelling of an exit code would pass it, and a bare `return 3` on a line that never says "exit" would pass it too. Both limits are written into the doc comment of the scan.

    Wire facts on the card, both confirmed against the resolved checkout and both load-bearing: `StopReason` carries six cases including `unknown(String)`, is not `CaseIterable`, so the test states an explicit list of six and pins the count at 6; `IdleStateUpdate.stopReason` is optional, so `idleWithNoReason` is `.success` and a test builds a bare `IdleStateUpdate()` to prove the field can be absent.

    Two judgment calls worth recording for the next agent:

    - `Equatable` was written on `AcpClientTimeout` and then removed. Nothing compares two of them, and the dead-code rule gives no credit for a consumer that has not arrived. `CustomStringConvertible` stays, matching `PromptSourceError` and `SubcommandNotImplementedError`, because an uncaught marker would otherwise print "AcpClientTimeout()" to a user.
    - `forDoctorStatus(_:)` looks near `DoctorReport.exitCode` upstream, which answers the same three numbers. It is not a reuse miss: that one takes a whole report and answers `Int32`, this one takes a `HealthStatus` and answers the enum, and building a `DoctorReport` to read one status would need a `HealthCheck` with a name, a message and a category the caller does not have. The relationship is stated in the doc comment instead. A cross-check test against `DoctorReport` was considered and dropped, because it would have needed a copy of the `makeCheck(reporting:)` factory that `ExtrasDoctorReachableTests` already owns privately.

    Verification: `swift test` — 161 tests in 10 suites, zero failures. A clean-scratch `swift build --build-tests` reported zero warnings and zero errors. The nested `IntegrationTests` package was not run.
  timestamp: 2026-09-04T16:58:57.250103+00:00
- actor: claude-code
  id: 01m1pnr0qqs6zbhvy7p7gpds0e
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/acp-client/ExitCode.swift (new), Sources/acp-client/AcpClient.swift (usageExitCode removed, processExitCode now returns AcpClientExitCode.usage.rawValue), Tests/FoundationModelsACPClientTests/ExitCodeTests.swift (new, 8 tests). `swift test`: 161 tests in 10 suites, 0 failures. Clean-scratch `swift build --build-tests`: 0 warnings, 0 errors. Every acceptance row and every test row on the card is checked.
    - next: /review
  timestamp: 2026-09-04T16:59:01.751644+00:00
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
- 01M1MPARCGY1FHKNED47MDBWG8
- 01M1MQEQYES0VD3F76KB55RRZ5
position_column: doing
position_ordinal: '80'
title: Map every outcome to the exit code table
---
## What

`cli-plan.md` §9 gives the exit code table, and §17 says the agent CLI uses the
same one. Put the mapping in one value with no I/O, so a test covers every row
and the two binaries can be compared line by line.

Create `Sources/acp-client/ExitCode.swift`:

- `enum AcpClientExitCode: Int32, Sendable, CaseIterable` with
  `success = 0`, `failure = 1`, `usage = 2`, `refusal = 3`, `cancelled = 4`,
  `doctorWarning = 5`, `timeout = 124`. Document each case with the §9 row and
  keep the note that code 5 exists because the Rust doctor's code 2 for errors
  would collide with the usage error.
- `static func forStopReason(_ reason: StopReason) -> AcpClientExitCode`.
  **`StopReason` has six cases, not five**: the generated union adds
  `case unknown(String)`, and decoding routes an unrecognized wire value into
  it rather than failing. So the switch needs all six arms, and the enum is
  **not** `CaseIterable` and holds an associated value, so no test can iterate
  it. Map `endTurn`, `maxTokens` and `maxTurnRequests` to `success`; `refusal`
  to `refusal`; `cancelled` to `cancelled`; and `.unknown` to `success`, with
  a comment: an agent that ended its turn for a reason this build does not
  know still ended its turn, and a non-zero code would make every future
  schema addition look like a failure.
- **An `idle` that carries no stop reason** is a completed turn. The field is
  optional in the schema — "Omitted or `null` both mean the agent is not
  reporting a stop reason" — so add
  `static let idleWithNoReason: AcpClientExitCode = .success` or map the
  `TurnOutcome` case to `success` at the call site, and say why. The
  documentation task adds this row to §9.
- `static func forDoctorStatus(_ status: HealthStatus) -> AcpClientExitCode`,
  over `FoundationModelsExtras.HealthStatus`: `ok` is `success`, `warning` is
  `doctorWarning`, `error` is `failure`.
- `static func forError(_ error: any Error) -> AcpClientExitCode`. An
  `ArgumentParser` validation or parsing error is `usage`; `AcpClientTimeout`
  is `timeout`; everything else — spawn, protocol and I/O — is `failure`.

Also add `struct AcpClientTimeout: Error` in the same file, the marker the
`--timeout` task throws.

## Acceptance Criteria

- [x] Every row of the §9 table has a case, and the raw values match.
- [x] `forStopReason` handles all six `StopReason` cases, `.unknown` included,
      with no `default` arm.
- [x] `forDoctorStatus` covers every `HealthStatus` case.
- [x] `forError` gives `usage`, `timeout` and `failure` for the three kinds
      above.
- [x] No file in `Sources/acp-client/` outside `ExitCode.swift` holds a bare
      numeric exit literal.

## Tests

- [x] New `Tests/FoundationModelsACPClientTests/ExitCodeTests.swift`. A
      table-driven test walks `AcpClientExitCode.allCases` and asserts each
      raw value against the §9 table, written out in the test as the expected
      pairs. This catches a renumbering.
- [x] A test asserts `forStopReason` against an explicit list of six values:
      `.endTurn`, `.maxTokens`, `.maxTurnRequests`, `.refusal`, `.cancelled`
      and `.unknown("something-new")`. Do not try to iterate the enum: it has
      an associated value and no `CaseIterable` conformance.
- [x] A test asserts `forDoctorStatus` for `ok`, `warning` and `error`, and
      `forError` for a `ValidationError`, an `AcpClientTimeout` and an
      `AgentProcessError.agentUnavailable`.
- [x] A test walks `Sources/acp-client/` with the shared
      `swiftSourceFiles(under:)` helper and asserts no file outside
      `ExitCode.swift` holds a bare numeric exit literal.
- [x] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.