---
comments:
- actor: claude-code
  id: 01m0ap3592emf3f3zzfy713xye
  text: |-
    Research notes:

    - The wire package (FoundationModelsACP) has no `session/load` method. The equivalent method is `session/resume` (`resumeSession`). The agent replays history as `session/update` notifications during that call. Thus the replay arrives through the same `Client.sessionUpdate` path as live updates.
    - The wire package has no history-invalidation signal (no `_meta` marker). Searched `Sources/FoundationModelsACP` for `invalidat`, `session/load`, `LoadSession`. We cannot implement the reload trigger. We must document the staleness limitation instead.
    - `SessionUpdateAggregator` is a value type. `ACPSessionState.applyUnbuffered(_:)` is complete for every update case. A rebuild can reuse that exact code path, so a replayed stream and a live stream produce equal state by construction.
    - Design: a two-phase API on `ACPSessionState` — `beginRehydration()` starts capture, `apply(_:)` captures replayed updates into a buffer while capture is active, `endRehydration()` discards the record projection and rebuilds it from the buffer in one synchronous main-actor pass. The UI thus never renders an empty intermediate state. `cancelRehydration()` discards the capture and keeps the prior state, for a failed `session/resume` call. Pending permission requests and their continuations survive a rebuild — they are live request state, not record state.
    - Plan: TDD. Tests first in a new RehydrationTests.swift, with stub methods so the tests compile, watch them fail, then implement.
  timestamp: 2026-08-18T14:58:31.842776+00:00
- actor: claude-code
  id: 01m0apn1s9hdjq2jhxxnapwgdz
  text: |-
    Implementation done, with the /tdd workflow.

    RED: wrote Tests/FoundationModelsACPClientTests/RehydrationTests.swift plus empty stub methods, and saw all 6 tests fail for the correct reasons (14 issues: stale content, two-time chunk content, no capture flag).

    GREEN: implemented the rehydration API on ACPSessionState:
    - `beginRehydration()` flushes the coalescing buffer and starts a capture. While the capture is active, `apply(_:)` puts each update into a capture buffer and does not touch the observable state, so a UI never shows an empty intermediate state.
    - `endRehydration()` discards the record projection (`resetRecordProjection()`) and applies the captured replay through `applyUnbuffered(_:)` — the same code path as a live stream. Thus a mid-session joiner that loads equals a fresh loader, and a second reload changes nothing.
    - `cancelRehydration()` discards the capture and keeps the prior state, for a failed `session/resume` call.
    - `isRehydrating` is observable, so a UI can show a reload indicator.
    - Pending permission requests and their continuations survive a rebuild. They are live request state, not record state.

    Decisions recorded:
    - The wire package has no `session/load`; `session/resume` (`resumeSession`) with `replayFrom: .start` is the replay mechanism. The tests include a wire-level `CompactingStubAgent` over `InMemoryTransport.pair()` that compacts between two prompt turns and replays its record during `resumeSession`. The tests assert both halves: the accumulating container is stale, and the reloading container converges.
    - UI across a rebuild: the prior state stays visible during the capture, and the swap is one synchronous main-actor pass. Correctness first; no empty flash.
    - ACP defines no history-invalidation signal at this time. The staleness before a reload is recorded as a known bug in README.md ("Known limitation: staleness after compaction") and in the ACPSessionState doc comment.

    Tests: full suite green — 46 tests, 0 failures, 0 warnings, `swift test` exit 0. No hang; the run completes in seconds.

    Files: Sources/FoundationModelsACPClient/ACPSessionState.swift, Tests/FoundationModelsACPClientTests/RehydrationTests.swift (new, 7 tests), README.md.
  timestamp: 2026-08-18T15:08:18.089134+00:00
- actor: claude-code
  id: 01m0apn3bv17txs05a2kwc5va5
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPClient/ACPSessionState.swift, Tests/FoundationModelsACPClientTests/RehydrationTests.swift, README.md; `swift test` green with 46 tests, 0 failures, 0 warnings
    - next: /review
  timestamp: 2026-08-18T15:08:19.707968+00:00
- actor: claude-code
  id: 01m0apptqt3prsqk2qnv7aacvx
  text: |-
    ### test — green
    - evidence: swift build (clean) — 0 warnings, build complete. swift test — 46 passed, 0 failed, 0 skipped.
    - next: none
  timestamp: 2026-08-18T15:09:16.410293+00:00
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: doing
position_ordinal: '80'
title: M4 Rehydrate from session/load, because the record is non-monotonic
---
## What

`plan.md` -> **Rehydration, because the record is non-monotonic**.

`session/update` is **append-only**, but the agent's record -- the FoundationModels `Transcript` -- is **rewritten by compaction**. Entries this container already displayed can cease to exist. A purely accumulating container therefore goes **silently stale**, and gets worse the longer a session lives, which is precisely the desktop case.

Make the container **rebuildable** rather than only accumulable:

- Build full state from a `session/load` replay, discarding prior accumulation.
- Reload on the agent's **history-invalidation signal** once `FoundationModelsACP` defines it (tracked there; a `_meta` marker with "reload from the record" semantics is the planned shape).
- Rebuild must be **idempotent and equivalent**: a container that joins mid-session and loads must reach the same state as one that streamed from the start (modulo genuinely lost pre-compaction history).
- Until the signal exists, **record the staleness as a known bug** in the README/docs rather than leaving it implicit.

Also decide what the UI shows *across* a rebuild: preserving scroll position and not flashing empty state matter, but correctness comes first.

## Acceptance Criteria

- [ ] State is fully reconstructible from `session/load`.
- [ ] The invalidation signal triggers a reload and convergence on post-compaction state (once ACP provides it).
- [ ] Rebuild is idempotent -- reloading twice changes nothing.
- [ ] A mid-session joiner reaches state equal to a fresh loader.
- [ ] The pre-signal staleness limitation is documented explicitly.

## Tests

- [ ] A stub agent that compacts mid-session: an accumulating container is demonstrably stale, one that reloads converges -- **assert both**, so the mechanism is proven necessary rather than assumed.
- [ ] Mid-session join + load equals fresh load, field for field.
- [ ] Double reload is a no-op.
- [ ] Reload while a turn is streaming does not corrupt the in-flight message or drop the turn.

## Workflow

- Use `/tdd` -- write failing tests first.
