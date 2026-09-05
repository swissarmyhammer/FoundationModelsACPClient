---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rrms3729v8yxqymxn7bffy
  text: |-
    Research, before the first edit.

    - The wire confirms the card. `KeyedDecodingContainer.forgivingDecodeIfPresent` in the ACP package is `(try? decodeIfPresent(type, forKey: key)) ?? nil`, and `forgivingDecodeArrayIfPresent` is built on it. A string, a number or an object in `authMethods` makes `decodeIfPresent` throw a type mismatch, `try?` swallows it, and the member becomes `nil`. A `null` member becomes `nil` the same way. Neither shape throws, so row 6 sees a decoded answer and reports `ok`.
    - `authMethodsLoss(in:keeping:)` in `Sources/AcpClientCore/AgentCommandDoctor.swift` reads the raw member with `as? [Any]`. A string is not `[Any]`, so the guard returns `nil` and the row has no loss to name. `JSONSerialization` gives `NSNull` for `null`, which is not `[Any]` either, so the fix must tell the two apart: `NSNull` is absent, and every other non-array value is a loss.
    - The `capabilities` half already does this in `membersTheDecodeDropped(from:keeping:)`: a value that is not an object names the member itself, and a `null` member is filtered with `is NSNull`.
    - The stub factory `makeAgent(pidFile:initialize:)` and `StubAgentInitializeAnswer` (commit 90cab90) are where a new answer shape goes. `initializeResult(reporting:protocolVersion:capabilities:unreadableAuthMethods:)` builds the array, so the member cannot be a string through it. The plan is to split out an overload that writes the raw member as given: `nil` leaves the member out, `NSNull()` writes `null`, a string writes a string.
    - The whole review rule file was read (11727 lines). The rules that bind these edits: every declaration carries a doc comment, every literal is named, no `guard` in a test, no force unwrap, functions stay short, tests in the nested package, no copied blocks.

    Plan (TDD, one arm at a time):
    1. Write the test for row 1 (string member warns and names `authMethods`) and the test for row 3 (a string member beside an unreadable `capabilities` member names both losses on one row). Run: both red.
    2. Implement the not-an-array loss. Run: both green.
    3. Write the test for row 2 (`null` still gives `ok`). Run: red, because the new arm reads `NSNull` as a loss.
    4. Treat `NSNull` as absent. Run: green. Then both suites.
  timestamp: 2026-09-05T12:28:10.215564+00:00
- actor: claude-code
  id: 01m1rrws6w2qp7ckk1hzst4k8t
  text: |-
    ### implement — changed

    - evidence: 3 files.
      - `Sources/AcpClientCore/AgentCommandDoctor.swift`: `authMethodsLoss(in:keeping:)` now reads the raw member in three steps. A missing member, or an `NSNull` member, is no loss. A member that is not `[Any]` returns the new `authMethodsShapeLoss`, a `DecodeLoss` whose message names `authMethods` and says the decode dropped it whole, with a fix that asks for the array the protocol states. An array keeps the count arm as it was. Rule 4 in the file header and the `capabilitiesCheck` doc state the new arm and the `null` case.
      - `IntegrationTests/.../Support/StubAgents.swift`: three `StubAgentInitializeAnswer` cases and three factories on the shared `makeAgent(pidFile:initialize:)`: `makeNonArrayAuthMethodsAgent` (sends `"authMethods": "stub-oauth"`), `makeNullAuthMethodsAgent` (sends `"authMethods": null`), and `makeUnreadableCapabilitiesAndNonArrayAuthMethodsAgent` (both shapes at once). `initializeResult` is split: the array-building overload now calls a new overload `initializeResult(authMethodsMember:protocolVersion:capabilities:)` that writes the member as given, where `nil` leaves it out and `NSNull()` writes `null`.
      - `IntegrationTests/.../AgentCommandDoctorTests.swift`: three tests, one for each acceptance row, and the header comment now counts five failing agents and three accepted ones.
    - red, then green (each test was seen red before its behavior landed):
      1. `aNonArrayAuthMethodsMemberWarnsOnTheCapabilitiesRow` and `aNonArrayAuthMethodsMemberIsNamedBesideADroppedCapabilitiesMember` written first. Run: both red. The first read `capabilities.status → .ok` with the message "every capability member and every authentication method the agent sent was read". The second read a message that named `session` and not `authMethods`. Then the not-an-array arm was added without the `NSNull` test. Run: both green.
      2. `aNullAuthMethodsMemberPassesTheCapabilitiesRow` written next. Run: red, `capabilities.status → .warning`, because the new arm read `NSNull` as a member of the wrong shape. Then `!(sent is NSNull)` was added to the first guard. Run: green, with the two tests above and `noAuthMethodsMemberPassesTheCapabilitiesRow` still green.
      3. Row 3 of the acceptance criteria is proven by test 2 of step 1 (both losses on one row, so the new arm stands beside the capabilities arm) and by the three existing tests that stay unchanged: `anUndecodableInitializeAnswerFailsTheCapabilitiesRow` (error arm), `unreadableCapabilitiesWarnOnTheCapabilitiesRow` and `unreadableAuthMethodWarnsOnTheCapabilitiesRow` (warning arms).
    - suites: `swift test` at the root: 223 tests in 19 suites passed. `swift test --package-path IntegrationTests`: 83 tests in 12 suites passed. Zero failures, zero compiler warnings, zero skipped. The two "Executed 0 tests" lines are the empty XCTest bundle of each package.
    - discovered: `cli-plan.md` §10 still says row 6 does not read `authMethods` and names ^1qfgtye as open. Recorded as a new card rather than edited here, because this card does not ask for a plan change.
    - next: `/review`. The task stays in `doing`.
  timestamp: 2026-09-05T12:32:32.476256+00:00
- actor: claude-code
  id: 01m1rrz4n9fvcqanzz338e3gtp
  text: |-
    ### test — green
    - evidence: `swift test` — 223 tests, 19 suites, 0 fail, 0 warn, 0 skip. `swift test --package-path IntegrationTests` — 83 tests, 12 suites, 0 fail, 0 warn, 0 skip.
    - No fix was needed. No file was changed.
    - next: ready for review.
  timestamp: 2026-09-05T12:33:49.737472+00:00
- actor: claude-code
  id: 01m1rs0gxhepenr373bytww3th
  text: |-
    ### commit — changed
    - evidence: e347890 feat(doctor): warn when authMethods is not null and not an array
  timestamp: 2026-09-05T12:34:35.057758+00:00
- actor: claude-code
  id: 01m1rsc51jqkb7kq25ye79ww12
  text: |-
    ### review — findings
    - scope: `review sha HEAD~1..HEAD` (commit e347890)
    - evidence: 1 finding — Sources/AcpClientCore/AgentCommandDoctor.swift:509
    - next: correct the open item in the `## Review Findings (2026-09-05 07:34)` section, then run the review again
  timestamp: 2026-09-05T12:40:56.114231+00:00
- actor: claude-code
  id: 01m1rscpsdcr1m41ee46kcjdz2
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 files: `Sources/AcpClientCore/AgentCommandDoctor.swift` (not-an-array arm in `authMethodsLoss`), `IntegrationTests/.../Support/StubAgents.swift` (3 answers, 3 factories), `IntegrationTests/.../AgentCommandDoctorTests.swift` (3 tests). Red then green for the string-member test, the two-losses test, and the `null` test.
    - test: green — root 223/223 in 19 suites, integration 83/83 in 12 suites, 0 warnings, 0 skipped
    - commit: e347890
    - review: findings — `Sources/AcpClientCore/AgentCommandDoctor.swift:509` (`completeness/invariant-propagation`: the comment says the row names a member that is not the object or the array the schema states, but `capabilityMembersLoss` has no explicit not-an-object check parallel to `authMethodsShapeLoss`)
  timestamp: 2026-09-05T12:41:14.285301+00:00
- actor: claude-code
  id: 01m1rsjn0fgxkkfx7dvm6cqvna
  text: |-
    Research for the open finding, before the first edit.

    What happens today when `capabilities` is a string:
    - The wire reads `capabilities` with `forgivingDecode(AgentCapabilities.self, forKey:, default: AgentCapabilities())`. That helper is `forgivingDecodeIfPresent(...) ?? fallback()`, so a string, a number, an array and `null` all become the empty default and nothing throws. Row 6 sees a decoded answer.
    - `membersTheDecodeDropped(from:keeping:)` reads the raw member with `as? [String: Any]`. A string is not that, so it returns `[capabilitiesKey]`. `capabilityMembersLoss` then builds the message "the agent sent capability members this build cannot read, and the decode dropped them: capabilities". So the row does warn, and the message does hold the word `capabilities`. The card was correct on that point.
    - The message is wrong in shape: it lists `capabilities` as if it were one dropped member OF the capabilities object, beside the fix "Send each capability in the shape the negotiated protocol version states". The `authMethods` half has its own `authMethodsShapeLoss` that says the member is not an array and the decode dropped it whole. The two halves are not parallel, and that is the finding.
    - A second divergence stands in the same code: `null` in `capabilities` is also not `[String: Any]`, so today it is reported as a loss named `capabilities`. Rule 4 in the file header says "a `null` member is absent, which the schema allows, and is no loss" for both members. The `authMethods` half treats `NSNull` as absent; the `capabilities` half does not.

    Plan (TDD, one arm at a time):
    1. Test: an agent that sends `capabilities` as a string warns on row 6, and the message names `capabilities` and says the member is not an object. Run: red, because today's message says "capability members ... dropped them: capabilities" and never says the shape.
    2. Make the two halves structurally parallel. One shared shape-loss builder makes both `authMethodsShapeLoss` and a new `capabilitiesShapeLoss`. `capabilityMembersLoss` reads the raw member in the same three steps `authMethodsLoss` does: absent is no loss, wrong shape is the shape loss, right shape is the member comparison. `membersTheDecodeDropped` then takes the members of the object, and no longer decides the shape. Run: green.
    3. Test: an agent that sends `capabilities` as `null` passes row 6. Run: red, because the new arm reads `NSNull` as a member of the wrong shape.
    4. One shared reader treats a `null` member as absent for both halves. Run: green. Then both suites.

    Stubs: two `StubAgentInitializeAnswer` cases and two factories on `makeAgent(pidFile:initialize:)`. The raw overload `initializeResult(authMethodsMember:protocolVersion:capabilities:)` types `capabilities` as `[String: Any]`, so it must take the member untyped to write a string or `null`.
  timestamp: 2026-09-05T12:44:29.071226+00:00
- actor: claude-code
  id: 01m1rsybg8a3vwp45x2979kqfc
  text: |-
    ### implement — changed

    Finding worked, word for word: `Sources/AcpClientCore/AgentCommandDoctor.swift:509` `completeness/invariant-propagation` — The comment at lines 509-510 (marked as changed) states that the row reports members "by name when it is not the object or the array the schema states". The code at line 618 adds an explicit type check for `authMethods` not being an array. However, `capabilityMembersLoss` lacks a corresponding explicit check for `capabilities` not being an object, despite the comment indicating both should be handled identically. Add an explicit type check in `capabilityMembersLoss` or at the start of `capabilitiesCheck` to detect when the `capabilities` member is not a dictionary/object, returning a shape loss message parallel to `authMethodsShapeLoss`.

    - evidence: 3 files.
      - `Sources/AcpClientCore/AgentCommandDoctor.swift`: `capabilityMembersLoss` now reads the raw member in the same three steps as `authMethodsLoss`: a member the agent left out or sent as `null` is no loss, a member that is not an object is the new `capabilitiesShapeLoss`, and an object is compared member by member. One shared builder, `shapeLoss(of:expecting:costing:)`, makes both `authMethodsShapeLoss` and `capabilitiesShapeLoss`, so the two messages cannot drift apart. One shared reader, `memberTheAgentSent(named:in:)`, treats a `null` member as absent for both halves. `membersTheDecodeDropped(from:keeping:)` now takes the members of the `capabilities` object and no longer decides the shape. The doc comments of the four functions state the arms.
      - `IntegrationTests/.../Support/StubAgents.swift`: two `StubAgentInitializeAnswer` cases and two factories on the shared `makeAgent(pidFile:initialize:)`: `makeNonObjectCapabilitiesAgent` (sends `"capabilities": "session"`) and `makeNullCapabilitiesAgent` (sends `"capabilities": null`). The raw overload `initializeResult(authMethodsMember:protocolVersion:capabilitiesMember:)` now takes the `capabilities` member untyped, so a string and `null` reach the wire.
      - `IntegrationTests/.../AgentCommandDoctorTests.swift`: two tests, and the header comment now counts six failing agents and four accepted ones.
    - red, then green:
      1. `aNonObjectCapabilitiesMemberWarnsOnTheCapabilitiesRow` written first. Run: red. The row did warn, and its message did hold the word `capabilities`, but it read "the agent sent capability members this build cannot read, and the decode dropped them: capabilities" and never said the shape. Then the shape-loss path landed. Run: green, with the four older row-6 tests green.
      2. `aNullCapabilitiesMemberPassesTheCapabilitiesRow` written next. Run: red, `capabilities.status → .warning`, because the new arm read `NSNull` as a member of the wrong shape. Then the shared reader landed. Run: green.
    - suites: `swift test` at the root: 223 tests in 19 suites passed. `swift test --package-path IntegrationTests`: 85 tests in 12 suites passed. Zero failures, zero compiler warnings, zero skipped. The two "Executed 0 tests" lines are the empty XCTest bundle of each package.
    - discovered: before this change, `capabilities: null` was reported as a loss named `capabilities`, against rule 4 in the file header, which says a `null` member is no loss for either member. The shared reader removes that divergence too, and the second test proves it.
    - next: `/review`. The task stays in `doing`.
  timestamp: 2026-09-05T12:50:52.552101+00:00
- actor: claude-code
  id: 01m1rt24d7v0dzryj7heexpzzs
  text: |-
    ### test — green
    - evidence: `swift test` — 223 tests, 19 suites, all passed, 0 failures, 0 warnings, 0 skipped. `swift test --package-path IntegrationTests` — 85 tests, 12 suites, all passed, 0 failures, 0 warnings, 0 skipped.
    - next: ready for the next step.
  timestamp: 2026-09-05T12:52:56.359213+00:00
- actor: claude-code
  id: 01m1rt3v5jkcqa4m46y59pyv03
  text: |-
    ### commit — changed
    - evidence: 7337f97 fix(doctor): read capabilities in the same three steps as authMethods
  timestamp: 2026-09-05T12:53:52.434891+00:00
- actor: claude-code
  id: 01m1rtbp9yaxb9jkpj5ye7k29a
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 7337f97) — 0 findings, 7 validator runs attempted, 0 failed; 3 files reviewed, 2 files in `.kanban/` excluded by `.reviewignore`. The one prior finding (2026-09-05 07:34) is checked.
    - next: none. The task moved to `done`.
  timestamp: 2026-09-05T12:58:09.598866+00:00
- actor: claude-code
  id: 01m1rtc76g5c9jfvtjqwwdq1fs
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — `Sources/AcpClientCore/AgentCommandDoctor.swift` (shared `shapeLoss` builder and `memberTheAgentSent` reader; `capabilityMembersLoss` reads absent, shape and members like `authMethodsLoss`), `IntegrationTests/.../Support/StubAgents.swift` (2 answers, 2 factories), `IntegrationTests/.../AgentCommandDoctorTests.swift` (2 tests, each red then green). 1 of 1 findings checked.
    - test: green — root 223/223 in 19 suites, integration 85/85 in 12 suites, 0 warnings, 0 skipped
    - commit: 7337f97
    - review: clean — 0 findings; task moved to `done`
  timestamp: 2026-09-05T12:58:26.896541+00:00
position_column: done
position_ordinal: a780
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

- [x] Row 6 reports a `warning` when the raw answer carries an `authMethods`
      member whose value is not `null` and not an array, and the message names
      the member.
- [x] An agent that sends `authMethods` as `null` still gives `ok`, because
      the schema lets the member be absent.
- [x] The row keeps its existing `error` and `warning` arms unchanged.

## Tests

- [x] Extend `StubAgents` with an agent that sends `authMethods` as a string.
- [x] Extend
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`
      with one test for each acceptance row.
- [x] Run both suites.

## Review Findings (2026-09-05 07:34)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Sources/AcpClientCore/AgentCommandDoctor.swift:509` `completeness/invariant-propagation` — The comment at lines 509-510 (marked as changed) states that the row reports members "by name when it is not the object or the array the schema states". The code at line 618 adds an explicit type check for `authMethods` not being an array. However, `capabilityMembersLoss` lacks a corresponding explicit check for `capabilities` not being an object, despite the comment indicating both should be handled identically. Add an explicit type check in `capabilityMembersLoss` or at the start of `capabilitiesCheck` to detect when the `capabilities` member is not a dictionary/object, returning a shape loss message parallel to `authMethodsShapeLoss`.
