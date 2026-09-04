---
assignees:
- claude-code
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
position_column: todo
position_ordinal: '8680'
title: Tee every ndJSON message to stderr for --frames
---
## What

`cli-plan.md` §6.1: "`--frames` is the reason the binary exists. It shows the
protocol exchange, so a person can see what an agent sent."

`AgentProcess` vends `transport` as `any ACPTransport`, and
`SwiftUIACPClient.connect(over:)` takes any transport, so the tee is a
pass-through wrapper. It needs no change in the wire package and no change in
this package's library. Model it on the existing
`DisconnectObservingTransport` in
`Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift`.

Create `Sources/acp-client/FrameTeeTransport.swift`:

- `final class FrameTeeTransport: ACPTransport, Sendable`. It wraps an inner
  transport and takes a `@Sendable (String) -> Void` sink that production
  points at stderr.
- Incoming bytes forward unchanged, and each **complete ndJSON line** is also
  written to the sink with an inbound direction mark. Chunk boundaries in
  `bytes` are arbitrary and need not align with lines, so the class buffers a
  partial line across chunks and emits only whole lines. A trailing partial
  line at end of stream is emitted with a marker that says it is incomplete.
- `write(_:)` forwards to the inner transport and writes the same bytes to the
  sink with an outbound direction mark.
- The direction marks are two fixed ASCII prefixes, chosen so a person reading
  a mixed log can sort the two directions, and pinned by a test.

The tee never decodes, never re-encodes and never reorders: a person debugging
an agent needs the bytes the agent actually sent.

## Acceptance Criteria

- [ ] The inner transport's bytes reach the consumer unchanged, byte for byte.
- [ ] A message split across three chunks is written to the sink one time, as
      one whole line.
- [ ] Two messages inside one chunk are written as two lines.
- [ ] An outbound write is written to the sink and reaches the inner
      transport.
- [ ] The sink sees each line with its direction mark, and the two marks
      differ.
- [ ] A trailing partial line at end of stream is reported as incomplete, and
      is not silently dropped.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/FrameTeeTransportTests.swift`.
      The tests drive `FrameTeeTransport` over a fake in-memory
      `ACPTransport`, with no process spawn. One test per acceptance row
      above.
- [ ] One test feeds a chunk that splits a multi-byte UTF-8 codepoint across
      the boundary and asserts the forwarded bytes are unchanged and the
      emitted line is correct.
- [ ] One test asserts the tee preserves order: inbound lines reach the sink in
      arrival order.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.