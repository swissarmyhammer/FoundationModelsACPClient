---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1ry4v8pgqa51mjbkezrtxsc
  text: |-
    Picked up. Research:

    - `cli-plan.md` §10 has two paragraphs on row 6. The second one says the row "does NOT yet read `authMethods`" and names ^1qfgtye as open work. Both are stale.
    - Source of truth is `Sources/AcpClientCore/AgentCommandDoctor.swift`: rule 4 in the file header, `capabilitiesCheck`, `capabilityMembersLoss`, `authMethodsLoss`, `memberTheAgentSent` and `shapeLoss`. The row reads the raw `result`, decodes it itself, and for each of `capabilities` and `authMethods`: a missing or `null` member is no loss; a member of the wrong shape (not an object / not an array) is a named WARNING; for the right shape, `capabilities` members are compared by name and `authMethods` elements by count. All losses go on one row.
    - The table row text (row 6 of the table) says "no member of `capabilities` is dropped in silence"; it must also name `authMethods`.
    - `Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift` reads the plan by section. I will add one test under `## 10.` that fails when the section says row 6 does not read `authMethods`, and show it red against the old text before the edit.
  timestamp: 2026-09-05T14:04:19.606885+00:00
- actor: claude-code
  id: 01m1ryesjh47dmjtge1nbmc11g
  text: |-
    RED evidence. Added `sectionTenStatesThatRowSixReadsEveryMember` to `Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift`, with `PlanSection.codeSpan`, `sentences(of:)` and `words(of:)` helpers. Against the old §10 text, `swift test --filter PlanDocumentTests` fails with 2 issues:

    - the check-table row that names `capabilities` does not name `authMethods` (row reads "The `initialize` answer decodes, and no member of `capabilities` is dropped in silence");
    - one sentence of §10 says the row does not read a member it reads: "The row does NOT yet read `authMethods`, which decodes in the same way, so an agent that sends a malformed `authMethods` gets no warning for it".

    The other 6 plan tests stay green. The two member names are test-local literals because `capabilitiesKey` and `authMethodsKey` are `private` at file scope in `AgentCommandDoctor.swift`, and widening them is outside a documentation card.
  timestamp: 2026-09-05T14:09:45.553693+00:00
- actor: claude-code
  id: 01m1ryj2kbktcamrf1d73zpa8n
  text: |-
    ### implement — changed
    - evidence: 2 files.
      - `cli-plan.md` §10: the check-table row for the decode check now reads "no member of `capabilities` and no element of `authMethods` is dropped in silence"; the row-6 paragraph now states the three cases for each of the two members — absent or `null` is no loss; a member of the wrong shape (a `capabilities` member that is not an object, an `authMethods` member that is not an array) is a WARNING that names the member; the correct shape is compared with the decoded value, `capabilities` by NAME and `authMethods` by COUNT alone, and every loss stands on the one row. The sentence "does NOT yet read `authMethods`" and the reference to ^1qfgtye are gone. No section was renumbered. The prose matches rule 4 and `capabilitiesCheck` in `Sources/AcpClientCore/AgentCommandDoctor.swift`.
      - `Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift`: new test `sectionTenStatesThatRowSixReadsEveryMember` plus `PlanSection.sentenceEnd`, `codeSpan(_:)`, `sentences(of:)` and `words(of:)`. Red against the old text (2 issues: the table row lacked `authMethods`; the sentence "The row does NOT yet read `authMethods` ..." was found), green after the edit.
      - `swift test`: 225 tests in 20 suites passed, 0 failures, 0 skipped, 0 compiler warnings. `swift test --package-path IntegrationTests`: 87 tests in 12 suites passed, 0 failures, 0 skipped.
      - No production code changed; `capabilitiesKey` and `authMethodsKey` stay `private`, so the test names the two members itself.
    - next: /review
  timestamp: 2026-09-05T14:11:33.099595+00:00
- actor: claude-code
  id: 01m1ryn454v197zpvqmzcdqa3h
  text: |-
    ### test — green
    - evidence: `swift test` — Test run with 225 tests in 20 suites passed after 0.789 seconds. 0 failures, 0 skipped.
    - evidence: `swift test --package-path IntegrationTests` — Test run with 87 tests in 12 suites passed after 21.827 seconds. 0 failures, 0 skipped.
    - evidence: `swift build` (root) and `swift build` (IntegrationTests) each show 0 lines with `warning:`.
    - next: /review
  timestamp: 2026-09-05T14:13:12.996230+00:00
- actor: claude-code
  id: 01m1ryptq8jan12zvhkpss7760
  text: |-
    ### commit — changed
    - evidence: c265c68 docs(plan): tell what doctor row 6 does with capabilities and authMethods
    - next: /review
  timestamp: 2026-09-05T14:14:08.872027+00:00
- actor: claude-code
  id: 01m1ryt8kb78h0zwqg9fhj1j2n
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit c265c68). counts: findings 0, confirmed 0, refuted 0, attempted 7, failed 0. 1 file reviewed. `cli-plan.md` had no validator that matches a Markdown file. `.kanban/` files are excluded by `.reviewignore`.
    - next: none. The card is in `done`.
  timestamp: 2026-09-05T14:16:01.387760+00:00
- actor: claude-code
  id: 01m1rytq2x578jrzptv5ayk336
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — `cli-plan.md` §10 (row 6 paragraph and table row rewritten; stale sentence and `^1qfgtye` reference removed), `Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift` (drift guard `sectionTenStatesThatRowSixReadsEveryMember`, red with 2 issues against the old text, green after)
    - test: green — root 225/225 in 20 suites, integration 87/87 in 12 suites, 0 warnings, 0 skipped
    - commit: c265c68
    - review: clean — 0 findings; task moved to `done`
  timestamp: 2026-09-05T14:16:16.221231+00:00
position_column: done
position_ordinal: ac80
title: 'cli-plan.md §10: describe the authMethods arms row 6 now has'
---
## What

Discovered while implementing ^jz39et3.

`cli-plan.md` §10, in the paragraph on the sixth row of the check table, says
the row "does NOT yet read `authMethods`" and that card ^1qfgtye holds that
work. Both statements are stale. Commit 48bccae (^1qfgtye) made the row count
the `authMethods` elements the forgiving decode dropped, and ^jz39et3 made it
name an `authMethods` member that is not an array. The plan is the document a
reader trusts for the doctor's contract, so it must describe what the row does.

## Acceptance Criteria

- [x] The §10 paragraph on row 6 states the three `authMethods` arms: elements
      dropped from an array are reported by count; a member that is not an
      array is named as that member; a `null` member is read as absent.
- [x] The paragraph no longer names ^1qfgtye as open work.
- [x] The text is in ASD-STE100 Simplified Technical English.

## Tests

- [x] None. This is a documentation change; `swift test` and the integration
      suite stay green. (The dispatch asked for one drift guard as well:
      `PlanDocumentTests.sectionTenStatesThatRowSixReadsEveryMember` fails
      when §10 again says row 6 ignores `authMethods`.)