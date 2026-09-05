---
assignees:
- claude-code
position_column: todo
position_ordinal: '9980'
title: 'Doctor row 6: also name the authMethods the forgiving decode dropped'
---
## What

Discovered while implementing ^t3y93w4 (doctor rows 6 and 7).

`InitializeResponse.authMethods` decodes through
`forgivingDecodeArrayIfPresent(of: AuthMethod.self, ...)`, and that helper
decodes each element inside a `FailableDecodeBox` and then `compactMap`s the
result. So an agent that advertises three authentication methods, one of which
this build cannot read, silently gives the client TWO. Nothing throws, and the
person who tries to log in with the third method is simply told it does not
exist.

The sixth row of the check table of `cli-plan.md` §10 now reads the raw
`initialize` answer, so it already has what it needs: the `authMethods` array
as the agent sent it. It compares the sent `capabilities` members with the
decoded ones and reports what was dropped, and it does NOT yet do the same for
`authMethods`.

## Acceptance Criteria

- [ ] Row 6 reports a `warning` when the raw answer's `authMethods` array holds
      more elements than `InitializeResponse.authMethods` kept, and the message
      says how many were dropped.
- [ ] An agent that advertises only readable methods still gives `ok`.
- [ ] An agent that sends no `authMethods` member still gives `ok`.
- [ ] The row keeps its existing `error` and `warning` arms unchanged.

## Notes

The count is the comparison to make, and not the content: `AuthMethod` is an
enumeration over the wire's own union, and this package must not spell what a
readable element looks like. A dropped element is one the raw array held and
the decoded array did not, so the arithmetic is the whole test.

## Tests

- [ ] Extend `StubAgents` with an agent that advertises one readable
      authentication method beside one this build cannot read.
- [ ] Extend
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`
      with one test for each acceptance row.
- [ ] Run both suites.