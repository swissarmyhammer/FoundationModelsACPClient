---
comments:
- actor: claude-code
  id: 01m0b851qfk01t6g60psyptg9h
  text: |-
    ### Research

    Findings from the code:

    - The wire package's `SessionUpdateAggregator` already holds the accumulation rules. `upsertTerminal` creates on first sighting and patches after that. A concrete `output` snapshot replaces the accumulated bytes. `appendTerminalOutputChunk` appends base64-decoded bytes. A chunk or snapshot that does not decode as base64 is dropped and does not corrupt the buffer. `AccumulatedTerminal` exposes `command`, `cwd`, `exitStatus`, `meta`, and `output`.
    - `ACPSessionState.terminals` already exposes `aggregator.terminals`, so the client role holds no second copy of the rules.
    - The generated code puts the `{"type": "terminal"}` content reference in `ToolCallContent` (`case terminal(Terminal)`), not in `ContentBlock`. A terminal reference inside message content decodes as `.unknown("terminal", payload)` by the generated fallback. The card's phrase "inside message or tool-call content" therefore maps to tool-call content only. This is not a blocker: the resolution helper takes the `Terminal` payload, which is the same value wherever it appears.

    What this package must add:

    1. A resolution helper: `ACPSessionState.terminal(for reference: Terminal) -> AccumulatedTerminal?`. An unknown id gives `nil`, which is the graceful degradation.
    2. A documented rendering fallback for bytes that are not valid UTF-8: `AccumulatedTerminal.transcript`, a lossy UTF-8 decode where each invalid sequence becomes U+FFFD. The decode never fails and never drops data; the raw bytes stay in `output`.
    3. Wire-driven tests per the card, over `InMemoryTransport.pair()` with a scripted stub agent. The private `StubAgent` in `WireConformanceTests.swift` moves to a shared test file so the new tests reuse it instead of copying it.

    Plan: TDD. Write the tests first, watch the new-API tests fail to compile, then add the two helpers.
  timestamp: 2026-08-18T20:14:08.111829+00:00
- actor: claude-code
  id: 01m0b8beg65679gyk4f2hhc4e4
  text: |-
    ### Implementation landed

    TDD sequence: the new test file failed to compile on the two missing members (`ACPSessionState.terminal(for:)` and `AccumulatedTerminal.transcript`), which was the RED step. The two members then made the build and the tests green.

    Changes:

    - `Sources/FoundationModelsACPClient/ACPSessionState+Terminals.swift` (new): `terminal(for:)` resolves a `{"type": "terminal"}` reference and gives `nil` for an unknown id; `transcript` is the documented rendering fallback — a lossy UTF-8 decode in which each invalid byte sequence becomes U+FFFD, with the raw bytes kept in `output`.
    - `Tests/FoundationModelsACPClientTests/TerminalDisplayTests.swift` (new): eight wire-driven tests over `InMemoryTransport.pair()` with a scripted stub agent — interleaved chunks, snapshot replaces (with a length assertion), invalid base64 chunk, invalid base64 snapshot, non-UTF-8 fallback, unseen-id creation with `command`/`cwd`/`exitStatus` observable, reference resolution, and unknown-reference degradation.
    - `Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift` (new): the scripted stub agent, moved out of `WireConformanceTests.swift` so both test files use one copy.
    - `Tests/FoundationModelsACPClientTests/WireConformanceTests.swift`: uses the shared `ScriptedStubAgent`.

    Notes for the next agent:

    - The `{"type": "terminal"}` content variant sits in `ToolCallContent`, not in `ContentBlock`. A terminal reference in message content decodes as `.unknown("terminal", payload)` by the generated fallback. The card's "message or tool-call content" phrase maps to tool-call content only; the resolution helper takes the `Terminal` payload, so it serves any position.
    - The aggregator's posture for invalid base64 is a silent drop that keeps the buffer intact. The tests assert that posture: no crash, no corruption.
    - The full `swift test` run did not hang: 61 tests, 0 failures, about 2 seconds.

    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPClient/ACPSessionState+Terminals.swift, Tests/FoundationModelsACPClientTests/TerminalDisplayTests.swift, Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift, Tests/FoundationModelsACPClientTests/WireConformanceTests.swift; swift test: 61 tests passed, 0 failures, 0 warnings
    - next: /review
  timestamp: 2026-08-18T20:17:37.798996+00:00
- actor: claude-code
  id: 01m0b8dtf8f53cj2ytw966kfsy
  text: |-
    ### test — green
    - evidence: `swift package clean && swift build` — build complete, 0 warnings. `swift build --build-tests` — build complete, 0 warnings. `swift test` — 61 tests, 0 failures, 0 skipped.
    - next: none.
  timestamp: 2026-08-18T20:18:55.592345+00:00
- actor: claude-code
  id: 01m0b8f52h50zgtwcc7hdbd5td
  text: |-
    ### commit — changed
    - evidence: 435dfcb feat(terminals): show terminal output owned by the agent
    - next: none
  timestamp: 2026-08-18T20:19:39.217466+00:00
- actor: claude-code
  id: 01m0b8kmqjprjcrr9nwakcpbms
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 0 confirmed, 0 refuted; 4 files reviewed
    - next: none. The task moved to done.

    step: review
    outcome: clean
    evidence: 0 findings, 0 confirmed, 0 refuted (review sha HEAD~1..HEAD)
    task: ^b04j6by
  timestamp: 2026-08-18T20:22:06.322597+00:00
- actor: claude-code
  id: 01m0b8m3p2p38b0g5n5vx8y6y3
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files (ACPSessionState+Terminals.swift new, TerminalDisplayTests.swift new, ScriptedStubAgent.swift new, WireConformanceTests.swift)
    - test: green — swift test, 61 passed, 0 failures, 0 warnings
    - commit: 435dfcb
    - review: clean — 0 findings on HEAD~1..HEAD; task moved to done
  timestamp: 2026-08-18T20:22:21.634004+00:00
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: done
position_ordinal: '8680'
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
