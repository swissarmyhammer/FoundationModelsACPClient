---
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: todo
position_ordinal: '8780'
title: M5 Render agent-owned display terminals
---
## What

`plan.md` -> **Display terminals are rendered, never driven**. Replaces the deleted filesystem task: v2 removed `fs/*` from the client role and, in the same move, removed all five `terminal/*` client methods -- so a client no longer *runs* terminals, it **renders** the ones the agent owns.

The surface is **verified real** in the vendored schema and generated code: `Schema/acp-v2.json` has `terminal_update` (line 3492), `terminal_output_chunk` (line 3508), and a `terminal` content variant (line 872); the generated `SessionUpdate` has `case terminalUpdate(TerminalUpdate)` and `case terminalOutputChunk(TerminalOutputChunk)`.

Surface to implement:

- content reference `{"type": "terminal", "terminalId": ...}` inside message or tool-call content;
- **`terminal_update`** upserts keyed by `terminalId`, patching `command`, absolute `cwd`, an output snapshot, and `exitStatus`;
- **`terminal_output_chunk`** appending **RFC 4648 base64-encoded bytes**.

Two details that are easy to get wrong:

1. **Output is bytes, not text.** Chunks are base64-encoded bytes, so decoding must handle non-UTF8 output -- a real shell emits it. Decide the rendering fallback (lossy conversion with a marker, or a sanitized transcript) and never crash or silently drop.
2. **A snapshot on `terminal_update` replaces; a chunk appends.** The spec calls the output field an *authoritative replacement snapshot* for replay, correction, or resynchronization. Treating it as another append duplicates the whole transcript.

No control surface: there is nothing to kill, release, or wait on. That is the protocol's design, and it is why this package needs no process discipline.

## Acceptance Criteria

- [ ] Terminals indexed by `terminalId`; `terminal_update` upserts (creates then patches).
- [ ] `terminal_output_chunk` appends decoded bytes in order.
- [ ] A snapshot on `terminal_update` **replaces** accumulated output.
- [ ] Non-UTF8 bytes render per a documented fallback without crashing or dropping data.
- [ ] `exitStatus`, `command`, and absolute `cwd` are observable.
- [ ] The `{"type": "terminal"}` content reference resolves to the right terminal.

## Tests

All tests drive a **stub agent over `InMemoryTransport.pair()`** and assert final observable state, per the plan's testing strategy -- `terminalUpdate` and `terminalOutputChunk` are `SessionUpdate` cases like any other.

- [ ] Interleaved chunks accumulate to exactly the concatenated decoded bytes.
- [ ] A snapshot mid-stream replaces rather than appends -- assert total length, since an append bug looks plausible until you measure it.
- [ ] Invalid base64 is a clean error, not a crash.
- [ ] Non-UTF8 bytes survive to the documented fallback rendering.
- [ ] `terminal_update` for an unseen id creates the terminal.
- [ ] A content reference to an unknown `terminalId` degrades gracefully.

## Workflow

- Use `/tdd` -- write failing tests first.
