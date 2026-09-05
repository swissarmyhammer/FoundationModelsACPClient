---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rpqcxf8x18jek4wgk4jbzg
  text: |-
    Research done.

    - `InitializeResponse.init(from:)` reads `authMethods` with `forgivingDecodeArrayIfPresent`. That helper decodes each element in a `FailableDecodeBox` and then `compactMap`s the result. An element the decode cannot read goes away with no error.
    - `AuthMethod.init(from:)` throws only for a missing `type` member or for a known `type` with a bad payload. An unknown `type` decodes to `.unknown`, so it is readable. A `{"type": "agent"}` element with no `methodId` and no `name` makes `AuthMethodAgent(from:)` throw, so the array decode drops it. That is the shape the new stub agent sends.
    - Row 6 in `AgentCommandDoctor.capabilitiesCheck` already reads the raw `result` member from the frame tee, decodes it, and compares the raw `capabilities` keys with the re-encoded decoded keys. The `authMethods` comparison goes beside it, as a count: raw array count minus `response.authMethods?.count ?? 0`.
    - The stub agents build the `initialize` answer in `initializeResult(reporting:protocolVersion:capabilities:)`. The `authMethods` member is built from `[AuthMethod]` through `jsonValue(of:)`. A new parameter carries the untyped elements this build cannot read.
    - Plan for the tests, one for each acceptance row: (1) a new stub that advertises one readable method beside one unreadable element gives `warning` and the message carries the dropped count; (2) `makeProbeAgent`, which advertises only readable methods, gives `ok`; (3) `makeWellBehavedAgent`, which sends no `authMethods` member, gives `ok`; (4) the existing tests `anUndecodableInitializeAnswerFailsTheCapabilitiesRow` and `unreadableCapabilitiesWarnOnTheCapabilitiesRow` prove the `error` and `warning` arms stay the same.
    - A raw `authMethods` value that is not an array is out of this card. The card compares counts of an array. That shape gets a new kanban task.
  timestamp: 2026-09-05T11:54:38.895603+00:00
- actor: claude-code
  id: 01m1rq7fr3r6ehtx5z3218r2vn
  text: |-
    Implementation landed, red then green.

    **Red first.** The three new tests in `AgentCommandDoctorTests.swift` went in before the doctor changed. `swift test --package-path IntegrationTests --filter AgentCommandDoctorTests` ran 18 tests: 17 passed, 1 failed. The failed one was `unreadableAuthMethodWarnsOnTheCapabilitiesRow`, with 3 issues: the row status was `.ok` and not `.warning`, the message was `every capability member the agent sent was read` and held no `dropped 1 of`, and the status list was all `.ok`. That is the correct failure: the row did not count `authMethods`. The two other new tests, `readableAuthMethodsPassTheCapabilitiesRow` and `noAuthMethodsMemberPassesTheCapabilitiesRow`, passed from the start. They guard the two arms that must stay `ok`, so they cannot be red against a correct row.

    **Green.** The same filtered run then passed all 18 tests.

    **What changed.**
    - `Sources/AcpClientCore/AgentCommandDoctor.swift`: row 6 now collects one `DecodeLoss` for each kind of loss. `capabilityMembersLoss(in:keeping:)` keeps the name comparison. `authMethodsLoss(in:keeping:)` reads the raw `authMethods` value as `[Any]` and subtracts `response.authMethods?.count ?? 0`; a count over zero is a warning whose message names the dropped count and the sent count. The row joins every loss into one warning, so one run names both kinds. `membersTheDecodeDropped` now takes the untyped answer members, so the raw answer is parsed one time. Rule 4 at the head of the file states the count comparison.
    - `IntegrationTests/.../Support/StubAgents.swift`: `stubAgentReadableAuthMethod` is now the first of `stubAgentAuthMethods`. `stubAgentUnreadableAuthMethodCount` drives the new `.reportsUnreadableAuthMethod` answer, which sends that one readable method beside an `agent` element that carries `id` in place of `methodId`. `initializeResult` takes the unreadable elements as untyped JSON after the readable ones. `makeUnreadableAuthMethodAgent(pidFile:)` writes the script.
    - `IntegrationTests/.../AgentCommandDoctorTests.swift`: three tests, one for each of the first three acceptance rows. Row 4 is held by the existing `anUndecodableInitializeAnswerFailsTheCapabilitiesRow` and `unreadableCapabilitiesWarnOnTheCapabilitiesRow`, and both still pass.

    **Suites.** `swift test` at the root: 223 tests in 19 suites passed, no warning, no skipped. `swift test --package-path IntegrationTests`: 80 tests in 12 suites passed, no warning, no skipped.

    **Discovery.** The first full integration run failed to build because the disk was full: 101 MiB free of 3.6 TiB, with about 55 GB of stale `CFNetworkDownload_*.tmp` files from Sep 2 in `$TMPDIR`. The space came back on its own a minute later and the run then passed. Nothing in this tree caused it.

    **New task.** ^jz39et3 covers a raw `authMethods` value that is not an array. This card compares counts of an array, and that shape gives the row nothing to count.
  timestamp: 2026-09-05T12:03:26.083065+00:00
- actor: claude-code
  id: 01m1rq7jpr81jnecqpw03ffksb
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/AcpClientCore/AgentCommandDoctor.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift. Red: the filtered doctor suite failed 1 of 18 (`unreadableAuthMethodWarnsOnTheCapabilitiesRow`, row 6 reported `ok`). Green: 18 of 18. `swift test`: 223 tests in 19 suites passed. `swift test --package-path IntegrationTests`: 80 tests in 12 suites passed. Zero failures, zero warnings, zero skipped.
    - next: /review
  timestamp: 2026-09-05T12:03:29.112903+00:00
- actor: claude-code
  id: 01m1rqbeaggcsxavnh1ddhnehk
  text: |-
    ### test — green
    - Command: `swift test` (root). Result: 223 tests, 19 suites, all pass. No failures. No skips. No warnings.
    - Command: `swift test --package-path IntegrationTests` (nested). Result: 80 tests, 12 suites, all pass. No failures. No skips. No warnings.
    - Disk space check: `df -h /` shows 325Gi free. No disk issue.
    - No probe changes left in the work tree. Git status shows only the prior implementation changes.
    - next: ready for review.
  timestamp: 2026-09-05T12:05:35.696121+00:00
position_column: doing
position_ordinal: '80'
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

- [x] Row 6 reports a `warning` when the raw answer's `authMethods` array holds
      more elements than `InitializeResponse.authMethods` kept, and the message
      says how many were dropped.
- [x] An agent that advertises only readable methods still gives `ok`.
- [x] An agent that sends no `authMethods` member still gives `ok`.
- [x] The row keeps its existing `error` and `warning` arms unchanged.

## Notes

The count is the comparison to make, and not the content: `AuthMethod` is an
enumeration over the wire's own union, and this package must not spell what a
readable element looks like. A dropped element is one the raw array held and
the decoded array did not, so the arithmetic is the whole test.

## Tests

- [x] Extend `StubAgents` with an agent that advertises one readable
      authentication method beside one this build cannot read.
- [x] Extend
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`
      with one test for each acceptance row.
- [x] Run both suites.