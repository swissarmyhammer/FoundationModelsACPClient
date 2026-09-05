---
assignees:
- claude-code
position_column: todo
position_ordinal: a180
title: Fold makeNewSessionRefusingAgent onto the shared stub-agent factory
---
## What

`IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift`
now has one private factory, `makeAgent(pidFile:initialize:)`. The five
factories that differ in their `initialize` answer alone call it. This fold
came from the review finding on ^1qfgtye.

`makeNewSessionRefusingAgent(pidFile:)` has the same shape. It calls
`writeAgentScript(requestLoop(...))` with `stubAgentDefaultAnswer`,
`.endTurn` and `pidFile`, and it differs from the shared factory in its
`newSession: .refuses` argument alone. ^1qfgtye folded the `initialize`
factories only, so this one still writes its own request loop.

## Acceptance Criteria

- [ ] `makeAgent(pidFile:initialize:)` takes a `newSession` parameter with the
      default `.answers`, or a second shared factory of the same shape takes
      the `newSession` answer.
- [ ] `makeNewSessionRefusingAgent(pidFile:)` calls the shared factory and
      writes no request loop of its own.
- [ ] No test assertion changes.

## Tests

- [ ] Run `swift test` at the root and `swift test --package-path IntegrationTests`.
      Zero failures, zero warnings, zero skipped.
