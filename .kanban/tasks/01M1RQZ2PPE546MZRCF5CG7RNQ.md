---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rthmr7bbh1fz68vxgcsvvp
  text: |-
    Research, before the edit.

    The shared factory `makeAgent(pidFile:initialize:)` in `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift` has ten callers now, not five: `makeWrongProtocolVersionAgent`, `makeInitializeRefusingAgent`, `makeMissingProtocolVersionAgent`, `makeUnreadableCapabilitiesAgent`, `makeNonObjectCapabilitiesAgent`, `makeNullCapabilitiesAgent`, `makeUnreadableAuthMethodAgent`, `makeNonArrayAuthMethodsAgent`, `makeNullAuthMethodsAgent` and `makeUnreadableCapabilitiesAndNonArrayAuthMethodsAgent`. Each one names one `initialize` answer.

    `makeNewSessionRefusingAgent(pidFile:)` writes its own request loop with `stubAgentDefaultAnswer`, `.endTurn`, `pidFile` and `newSession: .refuses`. That is the shape of the shared factory with one other answer. `requestLoop` already has the parameter `newSession: StubAgentRequestAnswer = .answers`.

    The two other factories that call `writeAgentScript(requestLoop(...))` with a default answer, `makeProbeAgent` and `makeSessionCloseRefusingAgent`, each name three answers, so they are not in the scope of this card.

    Tests that drive the factory to fold: `NoLeakedAgentTests.noAgentProcessOutlivesTheRun` for the rows `runReachesAnAgentThatRefusesTheSession` and `probeReachesAnAgentThatRefusesTheSession`, and `NoLeakedAgentTests.theWholeSweepRunsTwiceInARow`, which drives every row two times.

    Tests that drive the ten callers already folded: `ProbeCommandTests.anAgentThatRefusesInitializeFails` and the `initializes` row of `ProbeCommandTests` (`makeInitializeRefusingAgent`); in `AgentCommandDoctorTests`: `aWrongProtocolVersionFailsTheVersionRow` and the pid-file row at line 625 (`makeWrongProtocolVersionAgent`), `anUndecodableInitializeAnswerFailsTheCapabilitiesRow` (`makeMissingProtocolVersionAgent`), `unreadableCapabilitiesWarnOnTheCapabilitiesRow` (`makeUnreadableCapabilitiesAgent`), `unreadableAuthMethodWarnsOnTheCapabilitiesRow` (`makeUnreadableAuthMethodAgent`), `aNullAuthMethodsMemberPassesTheCapabilitiesRow` (`makeNullAuthMethodsAgent`), `aNonArrayAuthMethodsMemberWarnsOnTheCapabilitiesRow` (`makeNonArrayAuthMethodsAgent`), `aNonArrayAuthMethodsMemberIsNamedBesideADroppedCapabilitiesMember` (`makeUnreadableCapabilitiesAndNonArrayAuthMethodsAgent`), `aNonObjectCapabilitiesMemberWarnsOnTheCapabilitiesRow` (`makeNonObjectCapabilitiesAgent`), `aNullCapabilitiesMemberPassesTheCapabilitiesRow` (`makeNullCapabilitiesAgent`).

    Plan: give `makeAgent` the parameter `newSession: StubAgentRequestAnswer = .answers`, and give `initialize` the default `.reports([])`, which is the default of `requestLoop`. Each caller then names only the one answer it differs in. First change the caller, and show the build fails at the call site. Then widen the factory.
  timestamp: 2026-09-05T13:01:24.615367+00:00
- actor: claude-code
  id: 01m1rtncq29g8ezfvb2gs14ztt
  text: |-
    ### implement — changed
    - evidence: 1 file — `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift`. `makeAgent` now has the signature `makeAgent(pidFile:initialize:newSession:)`, with the defaults `initialize: .reports([])` and `newSession: .answers`, and it passes `newSession` to `requestLoop`. `makeNewSessionRefusingAgent(pidFile:)` now calls `makeAgent(pidFile: pidFile, newSession: .refuses)` and writes no request loop of its own. The doc comment of `makeAgent` names the new parameter. No factory signature changed. No test assertion changed.
    - counterfactual: with the caller changed and the factory not yet widened, `swift build --package-path IntegrationTests --build-tests` failed at the call site: `StubAgents.swift:431:18: error: incorrect argument label in call (have 'pidFile:newSession:', expected 'pidFile:initialize:')`. After the widening the same build passes.
    - tests that drive the folded factory: `NoLeakedAgentTests.noAgentProcessOutlivesTheRun` (rows `runReachesAnAgentThatRefusesTheSession` and `probeReachesAnAgentThatRefusesTheSession`) and `NoLeakedAgentTests.theWholeSweepRunsTwiceInARow`. The tests that drive the ten `initialize` callers are in the research comment above.
    - test counts: `swift test` at the root, 223 tests in 19 suites passed; `swift test --package-path IntegrationTests`, 85 tests in 12 suites passed. Zero failures, zero compiler warnings, zero skipped.
    - next: `/review`.
  timestamp: 2026-09-05T13:03:27.458467+00:00
- actor: claude-code
  id: 01m1rtsxn2hsp07cte8gqe7p13
  text: |-
    ### test — green
    - evidence: `swift test` (clean build) — 223 tests, 19 suites, 0 failures, 0 warnings, 0 skipped. `swift test --package-path IntegrationTests` (clean build) — 85 tests, 12 suites, 0 failures, 0 warnings, 0 skipped.
    - next: ready for review.
  timestamp: 2026-09-05T13:05:55.874070+00:00
position_column: doing
position_ordinal: '80'
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

- [x] `makeAgent(pidFile:initialize:)` takes a `newSession` parameter with the
      default `.answers`, or a second shared factory of the same shape takes
      the `newSession` answer.
- [x] `makeNewSessionRefusingAgent(pidFile:)` calls the shared factory and
      writes no request loop of its own.
- [x] No test assertion changes.

## Tests

- [x] Run `swift test` at the root and `swift test --package-path IntegrationTests`.
      Zero failures, zero warnings, zero skipped.
