---
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: todo
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

- [ ] Deltas are batched and flushed on a configurable display-rate cadence.
- [ ] Final text is byte-identical to concatenation of all chunks.
- [ ] Turn end (and connection close) flushes any buffer synchronously.
- [ ] Appends mutate the in-flight message in place; no array rebuild per chunk.
- [ ] Cadence is injectable so tests need no wall-clock sleeps.

## Tests

- [ ] N rapid chunks produce **far fewer than N** observable mutations -- assert the count, since this is the whole point of the task.
- [ ] Concatenation equality: final text equals the joined chunks exactly, including whitespace and unicode.
- [ ] A turn ending mid-buffer flushes the remainder.
- [ ] Interleaved message and thought chunks each coalesce into their own target without cross-contamination.
- [ ] No test depends on real elapsed time.

## Workflow

- Use `/tdd` -- write the failing mutation-count test first; it is the specification.
