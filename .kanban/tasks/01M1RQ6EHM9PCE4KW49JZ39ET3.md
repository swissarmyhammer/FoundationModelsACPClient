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
position_column: doing
position_ordinal: '80'
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