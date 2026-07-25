---
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: todo
position_ordinal: '8480'
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
