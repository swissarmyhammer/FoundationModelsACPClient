---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m412evp1q9hr0h39jj4wvxya
  text: |-
    Research done.
    - `SessionModel.apply(_:)` folds through `SessionMergeEngine` and reflects each `Change`. The entry classes write a field only when its value changes (`assign`), but each folded chunk gives a different content value. Thus a flush that reflects each change of N chunks writes the entry N times. The flush must collapse the changes of the buffer to the last change for each engine entry id (an `entryAdded` keeps its slot and takes the last entry state). Then N chunks give one write.
    - Stored properties and `deinit` must be in the class body. The coalescing state (cadence, clock, buffer, scheduled flush, tap continuations) goes in `SessionModel.swift`; the logic goes in the new `SessionModel+Coalescing.swift`.
    - The close path (`markClosed`) and the subscription come in ^ccdm82c. That card says `markClosed()` "finishes the `updateTap()` streams". This card adds an internal `finishUpdateTaps()` for it, and `deinit` also finishes the taps, so a released model never leaves a consumer suspended.
    - `SessionModelFoldTests.foldedModel` applies chunks and expects them at once. With the 33 ms default, those chunks would wait in the buffer. The helper changes to `coalescingCadence: .zero`.
    - `ManualClock`, `MutationCounter` and `yieldUntil` are in `CoalescingTests.swift`, which ^0w14d6x deletes with `ACPSessionState`. They move to a shared test-support file, so the new tests do not break when that file goes.
    - Validators: swift, code-hygiene (missing-docs, magic-numbers, dead-code with periphery), duplication, reuse, completeness, test-integrity. Read before code.
  timestamp: 2026-10-03T14:25:01.121921+00:00
- actor: claude-code
  id: 01m412sz1mtdse8sje2bd52yr2
  text: |-
    Implementation landed.
    - `SessionModel.apply(_:)` now gives the update to each tap first. A chunk (`agentMessageChunk`, `agentThoughtChunk`) goes into `pendingChunks` when the cadence is more than `.zero`; each other update flushes the buffer and then folds. The old one-update body is now `fold(_ updates:)`, which collapses the engine changes with `SessionMergeEngine.Change.collapsed(_:)`: one change for each entry, in the slot of its first change, with the state of its last change.
    - `isCoalescibleChunk` and the two `Change` helpers use exhaustive switches with no `default`.
    - `updateTap()` keeps one `AsyncStream.Continuation` for each tap, keyed by `UUID`. A tap whose consumer stopped is dropped at the next yield (`.terminated`). `finishUpdateTaps()` (internal) finishes all taps; `deinit` also finishes them and cancels the scheduled flush.
    - TDD: RED was the compile failure for the missing API in the new test file. After GREEN, a probe that made `collapsed` return its input made `chunksInsideOneCadenceWriteTheEntryOneTime` fail with `writes.value == 1` false, so the test catches a fold that writes the entry for each chunk. The probe is reverted.
    - For ^ccdm82c: `markClosed()` must call `flushPendingChunks()` and `finishUpdateTaps()`, and the end of the attached subscription must call `finishUpdateTaps()`. The `updateTap()` doc says that the stream finishes when the model closes.
  timestamp: 2026-10-03T14:31:05.012651+00:00
- actor: claude-code
  id: 01m412t5bvszp1v7mn8qzbztcc
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPClient/Model/SessionModel.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Coalescing.swift (new), Tests/FoundationModelsACPClientTests/Model/SessionModelCoalescingTests.swift (new, 14 tests), Tests/FoundationModelsACPClientTests/CoalescingTestSupport.swift (new; ManualClock, MutationCounter, yieldUntil moved from CoalescingTests.swift), Tests/FoundationModelsACPClientTests/CoalescingTests.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelFoldTests.swift. `swift test --filter SessionModelCoalescingTests`: 14 passed. `swift build`: complete. `swift test`: 342 tests in 30 suites passed, 0 failures. Warnings: only the permitted `SessionUpdateAggregator` deprecation and the MLX bundle "missing creator for mutated node".
    - next: /review
  timestamp: 2026-10-03T14:31:11.483615+00:00
- actor: claude-code
  id: 01m412z8x5zw9zney701adtpf3
  text: |-
    ### test — green
    - evidence: swift build — complete. swift test (root) — 342 tests in 30 suites passed, 0 failed, 0 skipped. swift build --package-path IntegrationTests — complete. swift test --package-path IntegrationTests — 103 tests in 14 suites passed, 0 failed, 0 skipped.
    - warnings: only the mlx-swift bundle warning and the SessionUpdateAggregator deprecations. Both are accepted.
    - flaky: none seen. The root suite ran one time.
    - next: review
  timestamp: 2026-10-03T14:33:58.949493+00:00
- actor: claude-code
  id: 01m412zp0pbswdbmv01qhbb8wr
  text: |-
    ### commit — changed
    - evidence: feat(model): coalesce chunks in SessionModel and add a raw update tap. 12 files. Tests: swift test 342/342, IntegrationTests 103/103.
    - next: review
  timestamp: 2026-10-03T14:34:12.374099+00:00
- actor: claude-code
  id: 01m413m99fj0v1hr1qca2xw8bs
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit c3ecd6d). 3 findings (3 confirmed, 3 refuted). Sources/FoundationModelsACPClient/Model/SessionModel+Coalescing.swift:29, Sources/FoundationModelsACPClient/Model/SessionModel+Coalescing.swift:68, Sources/FoundationModelsACPClient/Model/SessionModel.swift:147. All three are duplication/duplication against ACPSessionState.
    - next: implement the 3 findings in the dated Review Findings section. The task stays in review.
  timestamp: 2026-10-03T14:45:27.471862+00:00
- actor: claude-code
  id: 01m413mpta6e6jrm3fvtwzqpzb
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files (SessionModel+Coalescing.swift, tests, shared CoalescingTestSupport.swift)
    - test: green — swift test 342/342, IntegrationTests 103/103; only accepted warnings
    - commit: c3ecd6d feat(model): coalesce chunks in SessionModel and add a raw update tap
    - review: findings — Sources/FoundationModelsACPClient/Model/SessionModel+Coalescing.swift:29, Sources/FoundationModelsACPClient/Model/SessionModel+Coalescing.swift:68, Sources/FoundationModelsACPClient/Model/SessionModel.swift:147
  timestamp: 2026-10-03T14:45:41.322070+00:00
- actor: claude-code
  id: 01m414q42pbssbpavv43c0e07f
  text: |-
    Duplication fix landed (3 review findings).
    - New internal `@MainActor final class ChunkCoalescer` in `Sources/FoundationModelsACPClient/Model/ChunkCoalescer.swift`. It holds the buffer, the scheduled flush task (cadence + clock, weak self), the `.zero`-cadence rule, the coalescible-case rule (`isCoalescible`, exhaustive switch) and the default cadence (33 ms). The orchestration is `receive(_:)`: a chunk goes into the buffer; any other update calls `flush()` first and then the `applyUpdate` closure. `flush()` gives the batch to the `foldChunks` closure. `deinit` cancels the scheduled flush.
    - `SessionModel` and `ACPSessionState` each hold the coalescer as `@ObservationIgnored lazy var`, because the closures must capture `[weak self]` and a stored `let` cannot capture self in `init`. `@ObservationIgnored lazy var` compiles in an `@Observable` class.
    - `SessionModel.apply` = `yieldToUpdateTaps` + `coalescer.receive`. The tap behavior did not change. `flushPendingChunks()` forwards to `coalescer.flush()`. `isCoalescibleChunk`, `enqueue`, `scheduleFlushIfNeeded`, `pendingChunks`, `scheduledFlush` are deleted.
    - `ACPSessionState`: public API is the same. `PendingChunk`, `pendingChunk(for:)`, `enqueue`, `scheduleFlushIfNeeded`, `completeScheduledFlush`, `pendingChunks`, `scheduledFlush` and `deinit` are deleted. `applyUnbuffered` is now `reflect(update)` + `aggregator.apply(update)`. The new `foldBufferedChunks` folds the batch into one local aggregator copy and calls `reflect` for each chunk, so the flush and the immediate path use the same field projection. Both `defaultCoalescingCadence` constants read `ChunkCoalescer.defaultCadence`.
    - Behavior change to know: `ACPSessionState` with a `.zero` cadence now applies each chunk at once (before, it buffered the chunk until a zero-length sleep ended). The final state is the same; only the time is earlier. `AgentSession` uses `.zero`; all its tests pass.
    - TDD: RED was the compile failure "cannot find 'ChunkCoalescer' in scope" for the new `ChunkCoalescerTests` (10 tests). GREEN: 10 passed.
  timestamp: 2026-10-03T15:04:29.014678+00:00
- actor: claude-code
  id: 01m414q73wtfrcs7evbbzk9yrs
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPClient/Model/ChunkCoalescer.swift (new), Sources/FoundationModelsACPClient/Model/SessionModel.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Coalescing.swift, Sources/FoundationModelsACPClient/ACPSessionState.swift, Tests/FoundationModelsACPClientTests/Model/ChunkCoalescerTests.swift (new, 10 tests). `swift test --filter ChunkCoalescerTests`: 10 passed. `swift build`: complete; warnings only the permitted `SessionUpdateAggregator` deprecations and the MLX bundle "missing creator for mutated node". `swift test`: 352 tests in 31 suites passed, 0 failed (CoalescingTests, SessionStateTests, RehydrationTests, SessionModelCoalescingTests all pass). The 3 duplication findings are checked.
    - next: /review
  timestamp: 2026-10-03T15:04:32.124687+00:00
- actor: claude-code
  id: 01m41526jb53v2hyyh7hhwjhy1
  text: |-
    ### test - green (iteration 2, shared ChunkCoalescer)
    - evidence: swift build ok. swift test run 1 and run 2 at root: 352 tests in 31 suites passed, 0 failed, 0 skipped. swift build --package-path IntegrationTests ok. swift test --package-path IntegrationTests: 103 tests in 14 suites passed, 0 failed, 0 skipped. The stdout streaming tests passed.
    - warnings: only the MLX "missing creator for mutated node" warning and the SessionUpdateAggregator deprecations. Both are accepted.
    - next: review.
  timestamp: 2026-10-03T15:10:32.011504+00:00
- actor: claude-code
  id: 01m4152jwmq2favf5jk7fzcpqr
  text: |-
    ### commit — changed
    - evidence: refactor(model): share chunk coalescing between SessionModel and ACPSessionState, 8 files (swift test 352/352 two times, IntegrationTests 103/103)
    - next: review. A .zero cadence now applies each chunk at once in ACPSessionState.
  timestamp: 2026-10-03T15:10:44.628603+00:00
depends_on:
- 01M3YR0FJ4Z55VAXKXQ3KAM7GW
position_column: doing
position_ordinal: '80'
title: 'Model: SessionModel display-rate chunk coalescing and a raw update tap'
---
## What
Port the chunk coalescing of `ACPSessionState` to `SessionModel`, and add a raw update tap for non-UI consumers. New file `Sources/FoundationModelsACPClient/Model/SessionModel+Coalescing.swift`. Port the logic of `ACPSessionState.swift` (`pendingChunk(for:)`, `enqueue`, `scheduleFlushIfNeeded`, `flushPendingChunks`); do not copy the class.

- [x] `SessionModel.init(sessionId:, coalescingCadence: Duration = SessionModel.defaultCoalescingCadence (33 ms), clock: any Clock<Duration> = ContinuousClock())`.
- [x] `agent_message_chunk` and `agent_thought_chunk` go into a buffer that flushes on the cadence; any other update flushes first, then applies, so the applied order is the arrival order. `public func flushPendingChunks()`. With `.zero` cadence, each chunk applies at once.
- [x] `public func updateTap() -> AsyncStream<SessionUpdate>`: each raw update, in arrival order, at arrival time (not delayed by coalescing). The stream finishes when the model closes or its subscription ends. acp-client uses it to write chunks to stdout as they arrive.

## Acceptance Criteria
- [x] N chunks inside one cadence cause one observable write of the entry, and the final text is the same as one-by-one application.
- [x] A non-chunk update flushes the buffer before it applies.
- [x] `updateTap()` yields each update at once, also while the chunk buffer is not flushed.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Model/SessionModelCoalescingTests.swift`: port each case of `CoalescingTests.swift` with a manual clock; add tap order and tap timing tests.
- [x] `swift test --filter SessionModelCoalescingTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-10-03 09:34)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Sources/FoundationModelsACPClient/Model/SessionModel+Coalescing.swift:29` `duplication/duplication` — This implementation of flushPendingChunks duplicates nearly identical logic (0.96 similarity) already present in ACPSessionState.flushPendingChunks. When identical logic is duplicated across classes, fixes to one copy will need to be applied to the other to prevent drift. Extract the shared chunk flushing logic into a reusable helper or protocol extension that both SessionModel and ACPSessionState can use. The helper should accept a closure for the final operation (fold for SessionModel, whatever ACPSessionState uses) to handle the one differing line.
- [x] `Sources/FoundationModelsACPClient/Model/SessionModel+Coalescing.swift:68` `duplication/duplication` — This implementation of scheduleFlushIfNeeded is nearly identical (0.99 similarity) to ACPSessionState.scheduleFlushIfNeeded. The extremely high similarity indicates verbatim code that will need simultaneous maintenance if updated. Extract the task scheduling logic into a shared utility function. The differences are only in which properties are accessed (cadence, clock) and which method is called at completion (flushPendingChunks). Both can be parameterized to a single helper.
- [x] `Sources/FoundationModelsACPClient/Model/SessionModel.swift:147` `duplication/duplication` — The rewritten apply() method implementation duplicates nearly identical logic (0.86 similarity) from ACPSessionState.apply(). Both orchestrate the same sequence: yield to taps, check coalescibility, then either enqueue or flush-and-fold. This orchestration will need to be kept synchronized across both classes. Extract the shared apply() orchestration pattern into a common method or protocol extension that both SessionModel and ACPSessionState can use, parameterizing the differences (the enqueue vs. fold decision, the coalescing cadence check).
