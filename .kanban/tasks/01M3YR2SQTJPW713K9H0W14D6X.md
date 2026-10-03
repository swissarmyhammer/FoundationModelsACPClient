---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yrgnvfw3rz2wha98han0en
  text: 'Extra step (from foundationmodelsacp-c7, 2026-10-02): after this task is done and `swift build` gives no deprecation warnings for `SessionUpdateAggregator` or `updates(for:)`, send a message to the FoundationModelsACP session (foundationmodelsacp-c7): "ACPSessionState is gone; FoundationModelsACPClient no longer uses SessionUpdateAggregator or updates(for:)". That unblocks their task ^3wfc5m0, which removes both APIs.'
  timestamp: 2026-10-02T16:52:46.063507+00:00
depends_on:
- 01M3YRF6NEW4C85GZ34DENNHYK
- 01M3YR27ERN3DKRHMA1C5TYWBR
- 01M3YR6VEEG5QGMKHKQ7JPV3JX
position_column: todo
position_ordinal: 8a80
title: Remove ACPSessionState, SessionEntry, and SwiftUIACPClient; update the docs
---
## What
The old API does not need to be kept (decision of the user, through foundationmodelsacp-c7).

- [ ] BEFORE any delete: add a comment on this task with a table that maps each test case of `SessionStateTests.swift`, `CoalescingTests.swift`, `RehydrationTests.swift`, `TerminalDisplayTests.swift`, `PermissionRequestTests.swift`, `ElicitationTests.swift`, `InProcessConnectionTests.swift` to the named new test that covers the same behavior. Write a new test for each case that has none.
- [ ] Delete `Sources/FoundationModelsACPClient/ACPSessionState.swift`, `ACPSessionState+Terminals.swift`, `SessionEntry.swift`, `SwiftUIACPClient.swift`, `SwiftUIACPClient+Connect.swift` (its transport wrapper moved in task jge1qvf), and the seven old test files above.
- [ ] Update the test helpers that name the old types: the `drive(client:)` helper in `Tests/FoundationModelsACPClientTests/SessionUpdateFixtures.swift`, and the `SwiftUIACPClient` helper in `Tests/FoundationModelsACPClientTests/TransportTestSupport.swift`.
- [ ] Update the doc comments in `Sources/FoundationModelsACPClient/ACPClient.swift` and `Sources/FoundationModelsACPClient/AgentProcess.swift` that name `SwiftUIACPClient`.
- [ ] Update `README.md` (usage example with `ConnectionModel` and `SessionModel`) and `plan.md` (sections "The container", "Rehydration", "Pending requests") in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] Each old test case has a named new test in the mapping comment.
- [ ] `rg "ACPSessionState|SwiftUIACPClient|SessionEntry\b|SessionUpdateAggregator|hasReportedAvailableCommands" Sources Tests IntegrationTests README.md` finds nothing.
- [ ] `swift build` gives no warnings.

## Tests
- [ ] `ForbiddenImportTests.swift` and `ManifestTests.swift` still pass.
- [ ] `swift test` passes and `swift test --package-path IntegrationTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.