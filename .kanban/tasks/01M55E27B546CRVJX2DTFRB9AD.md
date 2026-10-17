---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m55eqadtw3bc0gba1at0nc54
  text: |-
    ### test — green
    - evidence: `swift test`: 642 tests in 51 suites pass. `IntegrationTests`: 1 test in 1 suite passes. Local Extras pin is `dd3a078` in both packages (Package.resolved is not tracked).
    ### review — clean
    - evidence: `review working`: 0 findings (7 attempted).
  timestamp: 2026-10-17T17:32:00.826470+00:00
position_column: done
position_ordinal: ff9480
title: PendingElicitation.validationIssue(of:) gives a typed issue that a UI can localize
---
Step 3 of the elicitation plan (Known gaps of AgentViewKit).

- Add `PendingElicitation.ValidationIssue` (with `Kind`, `ExpectedValue`, `StringFormat`, `failureText`). It is a type of ACPClient, not a typealias of Extras. Map each Extras case one-to-one.
- Add `PendingElicitation.validationIssue(of:)` with the same decode rules and the same nil cases as `validationFailure(of:)`.
- `validationFailure(of:)` gives `validationIssue(of:)?.failureText`.
- A test proves that each Extras kind maps to its ACPClient kind.
- Update Package.resolved to Extras `dd3a078` or later.
- Commit, push when the full run is green, send the public API to the coordinator.