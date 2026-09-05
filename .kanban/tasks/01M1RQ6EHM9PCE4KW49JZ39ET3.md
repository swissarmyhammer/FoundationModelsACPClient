---
assignees:
- claude-code
position_column: todo
position_ordinal: a080
title: 'Doctor row 6: report an authMethods member that is not an array'
---
## What

Discovered while implementing ^1qfgtye.

The sixth row of the check table of `cli-plan.md` §10 compares the raw
`authMethods` array with the decoded one by count. It reads the raw value with
`as? [Any]`, so an agent that sends `authMethods` as a string, a number or an
object gives the row nothing to count. `InitializeResponse` reads that member
with `forgivingDecodeArrayIfPresent`, which degrades a value that is not an
array to `nil` and throws nothing. The row then reports `ok`, and the client
silently believes the agent advertised no authentication method.

The `capabilities` half of the same row already names a `capabilities` member
that is not an object. See `membersTheDecodeDropped(from:keeping:)` in
`Sources/AcpClientCore/AgentCommandDoctor.swift`.

## Acceptance Criteria

- [ ] Row 6 reports a `warning` when the raw answer carries an `authMethods`
      member whose value is not `null` and not an array, and the message names
      the member.
- [ ] An agent that sends `authMethods` as `null` still gives `ok`, because
      the schema lets the member be absent.
- [ ] The row keeps its existing `error` and `warning` arms unchanged.

## Tests

- [ ] Extend `StubAgents` with an agent that sends `authMethods` as a string.
- [ ] Extend
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`
      with one test for each acceptance row.
- [ ] Run both suites.