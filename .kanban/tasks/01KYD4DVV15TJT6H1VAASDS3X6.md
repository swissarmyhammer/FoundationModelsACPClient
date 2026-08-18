---
comments:
- actor: claude-code
  id: 01m0ady87xw25nqrkct8bjajz5
  text: |-
    Research complete.

    Findings:
    - `ACPSessionState.apply(_:)` mutates the observable `aggregator` property one time for each chunk. It also sets `inFlightAgentMessageID` / `inFlightThoughtID` on each chunk. Thus N chunks cause approximately 2N observable mutations.
    - `SessionUpdateAggregator` (wire package) is a struct. A local copy can receive all buffered chunks, then one assignment back causes one observable mutation for each flush.
    - The `@ObservationIgnored` attribute keeps the chunk buffer out of observation, so buffering causes zero invalidations.
    - Non-chunk updates must flush the buffer first. This keeps the applied order identical to plain application, which gives byte-identical final text.
    - Turn end arrives as `state_update` (a non-chunk update), so the flush-before rule covers the turn-end flush.
    - Connection close: `SwiftUIACPClient.connectionState` gets a `didSet` that flushes all sessions when the value becomes `.disconnected`.
    - Clock injection: store `any Clock<Duration>` with a `ContinuousClock()` default. Tests use a manual clock that only moves when the test advances it.
    - Existing tests in SessionStateTests assert state immediately after chunk-only drives. The `drive` helper must flush at the end, and the two-session test must flush each session.

    Plan: TDD. Write the failing mutation-count test first, watch it fail, then implement coalescing in `ACPSessionState` plus the connection-close flush in `SwiftUIACPClient`.
  timestamp: 2026-08-18T12:36:02.429980+00:00
- actor: claude-code
  id: 01m0aepdgq5c5p63c5c91e7pmz
  text: |-
    Implementation complete, with the /tdd workflow.

    TDD record:
    - RED 1: `rapidChunksCauseFarFewerObservableMutationsThanChunks` failed with 203 mutations against the limit of 20 for 200 chunks. This shows the missing coalescing.
    - GREEN 1: `ACPSessionState` got a non-observable chunk buffer (`@ObservationIgnored`), a flush that folds all buffered chunks into one local `SessionUpdateAggregator` copy and writes it back one time, and a scheduled flush task on an injected clock. After this step the mutation count is a small constant (fewer than 20 for 200 chunks).
    - RED 2: `aConnectionCloseFlushesEveryBufferedSession` failed. GREEN 2: `SwiftUIACPClient.connectionState` got a `didSet` that flushes every session synchronously on `.disconnected`.
    - The card's other tests also landed: cadence flush with a manual clock, turn-end flush of a mid-buffer remainder, interleaved message/thought coalescing without cross contamination, and byte-identical concatenation with whitespace and unicode.

    Design facts:
    - Only `agent_message_chunk` and `agent_thought_chunk` coalesce. Every other update flushes the buffer first and then applies. Thus the applied order, and the final text, stays identical to plain one-by-one application.
    - A turn end arrives as `state_update`, so the flush-before rule gives the synchronous turn-end flush.
    - `flushPendingChunks()` is public, so a host can flush at any boundary.
    - The cadence and the clock are injectable: `ACPSessionState(coalescingCadence:clock:)` and `SwiftUIACPClient(coalescingCadence:clock:)`, default `.milliseconds(33)` and `ContinuousClock`. Tests use a `ManualClock` (a full `Clock` conformance with cancellation support), so no test reads the wall clock.
    - The flush appends into the in-flight message in place (`messages[id, default: []].append`), with one observable aggregator write for each flush. The in-flight id only mutates when it changes.
    - The test `drive` helper now flushes at the end, so the existing assertions read landed state. The two-session test flushes each session.

    What did not work: the first cadence test advanced the manual clock before the flush task registered its sleeper, so the flush never fired. The fix is `ManualClock.sleeperCount` plus a cooperative wait before the advance. No wall-clock sleep was added.

    Verification: `swift test` — 33 tests, 0 failures, 0 warnings, 5 stable repeat runs.
  timestamp: 2026-08-18T12:49:14.263209+00:00
- actor: claude-code
  id: 01m0aepjht2agrc0n6vc1zv3re
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPClient/ACPSessionState.swift, Sources/FoundationModelsACPClient/SwiftUIACPClient.swift, Tests/FoundationModelsACPClientTests/CoalescingTests.swift (new), Tests/FoundationModelsACPClientTests/SessionUpdateFixtures.swift, Tests/FoundationModelsACPClientTests/SessionStateTests.swift. `swift test`: 33 tests, 0 failures, 0 warnings. Mutation count: 200 rapid chunks give fewer than 20 observable mutations (203 before the change).
    - next: /review
  timestamp: 2026-08-18T12:49:19.418717+00:00
- actor: claude-code
  id: 01m0aerg8mxs80n6n6dzevcz3e
  text: |-
    ### test — green
    - evidence: `swift build` (clean, after `rm -rf .build`) — build complete, 0 warnings, 0 errors. `swift test` — 33 tests passed, 0 failed, 0 skipped.
    - next: none. The build is clean.
  timestamp: 2026-08-18T12:50:22.612711+00:00
- actor: claude-code
  id: 01m0aeswvby1z4e8k7yn7xjt7j
  text: |-
    ### commit — changed
    - evidence: f4d0a5c feat(session-state): group fast token chunks before they update the view
    - next: none
  timestamp: 2026-08-18T12:51:08.267329+00:00
- actor: claude-code
  id: 01m0aeywydhc5qs0dxem668aya
  text: |-
    ### review — findings
    - evidence: 2 findings — Sources/FoundationModelsACPClient/ACPSessionState.swift:102, Tests/FoundationModelsACPClientTests/CoalescingTests.swift:20
    - next: correct the two findings, then run the review again

    step: review
    outcome: findings
    evidence: 2 findings — Sources/FoundationModelsACPClient/ACPSessionState.swift:102, Tests/FoundationModelsACPClientTests/CoalescingTests.swift:20
    task: ^asds3x6
  timestamp: 2026-08-18T12:53:52.205536+00:00
- actor: claude-code
  id: 01m0aezf9fzhqf92wk1q21kep7
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files (ACPSessionState.swift, SwiftUIACPClient.swift, CoalescingTests.swift new, SessionUpdateFixtures.swift, SessionStateTests.swift)
    - test: green — swift test, 33 passed, 0 failures, 0 warnings
    - commit: f4d0a5c
    - review: findings — Sources/FoundationModelsACPClient/ACPSessionState.swift:102, Tests/FoundationModelsACPClientTests/CoalescingTests.swift:20
  timestamp: 2026-08-18T12:54:10.991973+00:00
- actor: claude-code
  id: 01m0af36jd0bf1pf3kjnf1f6gv
  text: |-
    Finding correction complete.

    The rule is swiftlint `no_magic_numbers`. It permits a literal in a direct declaration, but it reports a literal that is a function argument. Both flagged lines had the shape `.milliseconds(<literal>)`, so each literal now has its own named constant:

    - `ACPSessionState.swift`: `defaultCoalescingCadenceMilliseconds = 33` (private static let), and `defaultCoalescingCadence` now reads `.milliseconds(defaultCoalescingCadenceMilliseconds)`.
    - `CoalescingTests.swift`: `testCadenceMilliseconds = 40` (private let), and `testCadence` now reads `.milliseconds(testCadenceMilliseconds)`.

    A search of the whole package for literals in argument position found no other cause: the only other matches are `Mutex(0)` and `.minutes(1)`, and the rule permits `0` and `1`.

    The card checkboxes are now current: both findings are checked, and all 10 acceptance and test checkboxes are checked, because the M2 coalescing work satisfies them and the tests hold them.

    Verification: `swift test` — 33 tests, 0 failures, 0 warnings.
  timestamp: 2026-08-18T12:56:13.133261+00:00
- actor: claude-code
  id: 01m0af3c15aax7h3r2qmmdbqwd
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPClient/ACPSessionState.swift, Tests/FoundationModelsACPClientTests/CoalescingTests.swift. 2 findings corrected and checked. `swift test`: 33 tests, 0 failures, 0 warnings. 10 acceptance and test checkboxes checked.
    - next: /review

    step: implement
    outcome: changed
    evidence: 2 files — Sources/FoundationModelsACPClient/ACPSessionState.swift, Tests/FoundationModelsACPClientTests/CoalescingTests.swift; 2 findings corrected; swift test 33 passed, 0 failures, 0 warnings
    task: ^asds3x6
  timestamp: 2026-08-18T12:56:18.725803+00:00
- actor: claude-code
  id: 01m0af4z5rrcjp9ww1bt7jjapr
  text: |-
    ### test — green
    - evidence: swift build (clean, 0 warnings, 0 errors) and swift test — 33 passed, 0 failed, 0 skipped
    - next: none
  timestamp: 2026-08-18T12:57:11.096050+00:00
- actor: claude-code
  id: 01m0af5p07nnttrbjgpbfm4q8h
  text: |-
    ### commit — changed
    - evidence: ca98afc refactor(session-state): use named constants for cadence values
    - next: none
  timestamp: 2026-08-18T12:57:34.471223+00:00
- actor: claude-code
  id: 01m0af92edbmwzv9jq1t4wmsg9
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 0 confirmed, 0 refuted. All items in the section "Review Findings (2026-08-18 07:51)" have the checked state.
    - next: none. The task moved to the done column.

    step: review
    outcome: clean
    evidence: review sha HEAD~1..HEAD — counts: 0 findings, 0 confirmed, 0 refuted; all items in the section "Review Findings (2026-08-18 07:51)" have the checked state
    task: ^asds3x6
  timestamp: 2026-08-18T12:59:25.517969+00:00
- actor: claude-code
  id: 01m0af9nxna98pq7qe5m2r3386
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 2 files; 2 review findings corrected and checked
    - test: green — swift test, 33 passed, 0 failures, 0 warnings
    - commit: ca98afc
    - review: clean — 0 findings on HEAD~1..HEAD; task moved to done
  timestamp: 2026-08-18T12:59:45.461957+00:00
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: done
position_ordinal: '8280'
title: M2 Coalesce token-rate chunks so SwiftUI does not thrash
---
## What

`plan.md` -> **Coalescing is a requirement, not an optimization**.

`agentMessageChunk` arrives at token rate. Applying each one to an `@Observable` on the main actor triggers a SwiftUI invalidation per token, which will visibly degrade a real UI.

Batch incoming deltas and flush on a **display-rate cadence**, appending into the in-flight message rather than rebuilding arrays. Apply the same treatment to `agentThoughtChunk`.

Requirements:

- Final text must be **byte-identical** to plain concatenation -- coalescing may not lose, reorder, or merge across message boundaries.
- A turn ending must flush immediately, so the last partial chunk is never left buffered.
- Cadence must be configurable and testable without real time (inject the clock).

**This gets measured, not assumed.** The acceptance criterion is a number, not a claim.

## Acceptance Criteria

- [x] Deltas are batched and flushed on a configurable display-rate cadence.
- [x] Final text is byte-identical to concatenation of all chunks.
- [x] Turn end (and connection close) flushes any buffer synchronously.
- [x] Appends mutate the in-flight message in place; no array rebuild per chunk.
- [x] Cadence is injectable so tests need no wall-clock sleeps.

## Tests

- [x] N rapid chunks produce **far fewer than N** observable mutations -- assert the count, since this is the whole point of the task.
- [x] Concatenation equality: final text equals the joined chunks exactly, including whitespace and unicode.
- [x] A turn ending mid-buffer flushes the remainder.
- [x] Interleaved message and thought chunks each coalesce into their own target without cross-contamination.
- [x] No test depends on real elapsed time.

## Workflow

- Use `/tdd` -- write the failing mutation-count test first; it is the specification.

## Review Findings (2026-08-18 07:51)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPClient/ACPSessionState.swift:102` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsACPClientTests/CoalescingTests.swift:20` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
