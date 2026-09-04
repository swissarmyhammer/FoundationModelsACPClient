---
assignees:
- claude-code
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
- 01M1MPARCGY1FHKNED47MDBWG8
- 01M1MQEQYES0VD3F76KB55RRZ5
position_column: todo
position_ordinal: '8480'
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

- [ ] Every row of the §9 table has a case, and the raw values match.
- [ ] `forStopReason` handles all six `StopReason` cases, `.unknown` included,
      with no `default` arm.
- [ ] `forDoctorStatus` covers every `HealthStatus` case.
- [ ] `forError` gives `usage`, `timeout` and `failure` for the three kinds
      above.
- [ ] No file in `Sources/acp-client/` outside `ExitCode.swift` holds a bare
      numeric exit literal.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/ExitCodeTests.swift`. A
      table-driven test walks `AcpClientExitCode.allCases` and asserts each
      raw value against the §9 table, written out in the test as the expected
      pairs. This catches a renumbering.
- [ ] A test asserts `forStopReason` against an explicit list of six values:
      `.endTurn`, `.maxTokens`, `.maxTurnRequests`, `.refusal`, `.cancelled`
      and `.unknown("something-new")`. Do not try to iterate the enum: it has
      an associated value and no `CaseIterable` conformance.
- [ ] A test asserts `forDoctorStatus` for `ok`, `warning` and `error`, and
      `forError` for a `ValidationError`, an `AcpClientTimeout` and an
      `AgentProcessError.agentUnavailable`.
- [ ] A test walks `Sources/acp-client/` with the shared
      `swiftSourceFiles(under:)` helper and asserts no file outside
      `ExitCode.swift` holds a bare numeric exit literal.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.