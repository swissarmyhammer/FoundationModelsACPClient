---
comments:
- actor: wballard
  id: 01kyd5cntvcp04pwdksv80vc1e
  text: |-
    ## Reframed for ACP v2 -- rehydration is now protocol, not a workaround

    This task was written for v1, where `session/update` is append-only and the only plan was a bespoke `_meta` history-invalidation marker that `FoundationModelsACP` would have had to invent.

    **v2 makes replay first-class, and the invented signal is unnecessary:**

    - **`session/load` is gone.** **`session/resume`** handles both cases: omit `replayFrom` for a plain reconnect, or send **`replayFrom: {"type": "start"}`** to replay the entire conversation *as ordinary session updates*.
    - **Whole-message upserts** can replace or clear content (`null`/`[]`), so history is correctable rather than append-only.
    - **`messageId` is required and agent-generated** -- the agent owns history and identity.

    So: build state from a `replayFrom: start` resume, discarding prior accumulation. The container rebuilds **by asking**.

    Requirements that still stand: rebuild must be **idempotent** (resuming twice changes nothing), and a mid-session joiner must reach the same state as one that streamed from the start.

    **One genuinely open question, and it is not this package's to answer:** nothing in v2 obviously *pushes* "history was rewritten" to a connected client. So how does a live client learn it should resume after the agent compacts? Likely policy rather than protocol -- e.g. resume on reconnect, or the agent re-emits affected messages as upserts. Raise it with `FoundationModelsACPAgent`; until it is settled, a long-lived connected client can still drift even on v2, and that limitation should be documented rather than assumed away.

    Drop from this task: the `_meta` invalidation-marker design and the dependency on ACP defining it.
  timestamp: 2026-07-25T17:32:57.563583+00:00
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: todo
position_ordinal: '8480'
title: M4 Rehydrate from session/resume, because the record is non-monotonic
---
## What

`plan.md` -> **Rehydration, because the record is non-monotonic**.

The agent's record -- the FoundationModels `Transcript` -- is **rewritten by compaction**. Entries this container already displayed can cease to exist. A purely accumulating container therefore goes **silently stale**, and gets worse the longer a session lives, which is precisely the desktop case.

v2 answers this directly. `session/resume` (`Agent.resumeSession(ResumeSessionRequest)`) with `replayFrom: .start` makes full history replay a **first-class request**: the agent replays history as ordinary session updates. Combined with whole-message upserts (M1) and agent-owned `messageId`, the protocol says what the record says. There is **no `session/load` in v2**, and no bespoke invalidation signal exists or is needed -- the container **rebuilds by asking**.

Make the container **rebuildable** rather than only accumulable:

- Build full state from `session/resume` with `replayFrom: .start`, discarding prior accumulation.
- Policy, not protocol: **resume with full replay on reconnect**, and whenever the app chooses to resynchronize. Document this policy.
- Rebuild must be **idempotent and equivalent**: a container that joins mid-session and resumes must reach the same state as one that streamed from the start (modulo genuinely lost pre-compaction history).

Also decide what the UI shows *across* a rebuild: preserving scroll position and not flashing empty state matter, but correctness comes first.

## Acceptance Criteria

- [ ] State is fully reconstructible from `session/resume` with `replayFrom: .start`.
- [ ] Resume-on-reconnect policy is implemented and documented.
- [ ] Rebuild is idempotent -- resuming twice changes nothing.
- [ ] A mid-session joiner reaches state equal to a fresh resumer.

## Tests

- [ ] A stub agent that compacts mid-session: an accumulating container is demonstrably stale, one that resumes converges -- **assert both**, so the mechanism is proven necessary rather than assumed.
- [ ] Mid-session join + resume equals fresh resume, field for field.
- [ ] Double resume is a no-op.
- [ ] Resume while a turn is streaming does not corrupt the in-flight message or drop the turn.

## Workflow

- Use `/tdd` -- write failing tests first.
