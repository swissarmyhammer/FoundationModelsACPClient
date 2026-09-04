---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1pbt63zh28p3xhdvetc07c2
  text: |
    Research done.

    Findings that shape the build:

    - `ACPTransport` (wire package, `Transport/NDJSONCodec.swift`) is two members: `var bytes: AsyncThrowingStream<Data, any Error>` and `func write(_ data: Data) async throws`. Its own doc says chunk boundaries "need not align with lines or UTF-8 codepoints", which is exactly the case the tee must buffer across.
    - The wire package already owns the buffering: `public struct NDJSONFramer` has `mutating func append(_ chunk: Data) -> [Data]` (whole lines, newline stripped) and `mutating func finish() -> Data?` (the retained unterminated tail). The tee reuses it rather than writing a splitter of its own.
    - `DisconnectObservingTransport` in `Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift` gives the shape to copy: a `let bytes` built from `AsyncThrowingStream.makeStream()`, a forwarding `Task` that reads `inner.bytes` and yields each chunk unchanged, `continuation.onTermination` cancelling that task, a `deinit` that cancels it too, and a `write(_:)` that goes straight to `inner`.
    - The tests can drive the tee over `InMemoryTransport.pair()` from the wire package. `write(_:)` on one end yields the exact `Data` to the peer's `bytes`, so a test controls chunk boundaries byte for byte, and `close()` gives the end of stream the incomplete-tail row needs. That is an in-memory transport with no process spawn, so no hand-written fake is needed.
    - `SharedOptions.frames` already exists in `Sources/acp-client/SharedOptions.swift`. Wiring it is ^3cat35c, not this card.

    Design decisions:

    - Outbound `write(_:)` tees one sink call per write, and does not run a framer. The wire writes one whole frame per call (`NDJSONCodec.encode` appends exactly one `\n`, and `ACPTransport.write` is contracted atomic), so line buffering on that side would buy nothing and could hide a frame.
    - The sink contract is one line without its terminator, in both directions, so a production sink adds its own newline the way `ACPLogger.standardError` does. The outbound side drops one trailing newline for that reason; it drops framing only, never content.
  timestamp: 2026-09-04T14:05:27.039020+00:00
- actor: claude-code
  id: 01m1pc8axh53ej8xd2am5rmbsa
  text: |
    TDD record, in order.

    1. RED, compile: wrote `FrameTeeTransportTests.swift` first. `swift test` refused to build — "cannot find type 'FrameTeeTransport' in scope", 11 times.
    2. RED, assertions: added a skeleton `FrameTeeTransport` that forwards bytes and calls no sink. 8 tests, 8 issues; the one row that already held was "the inner transport's bytes reach the consumer unchanged", which is right, because pass-through was all the skeleton did.
    3. GREEN: added the framer, the two direction marks, the incomplete tag and the outbound tee. 8 of 8 pass; the whole suite is 119 of 119, and `swift build --build-tests` emits no warning.

    What the implementation does, beyond the card text:

    - The inbound line reaches the sink BEFORE the chunk is yielded to the consumer, and the outbound line reaches it AFTER the inner transport accepted the bytes. One rule covers both: a line is logged at the moment its crossing is a fact. So a line in the log is a line that moved, and a write that throws logs nothing.
    - The tail is emitted on both stop paths, the clean end of stream and the failure, because either one can leave a partial line buffered.
    - Outbound loses exactly one trailing newline and nothing else, so a sink that adds its own line ending (as `ACPLogger.standardError` does) does not print a blank line between frames.

    Rules checked before the review step, on both new files:

    - swiftlint with the validator's own settings for `no_magic_numbers` (allowed `[0, 1, -1, 100]`), `missing_docs`, `function_body_length`, `closure_body_length` and the force-construct rules: clean.
    - swiftformat `--lint` over the 22 applicable Airbnb rules, `preferFinalClasses`, `noGuardInTests`, `swiftTestingTestCaseNames` and `testSuiteAccessControl` among them: 0 of 2 files need formatting.
    - Two findings were corrected in the test file before the run: a top-level `func joined` (the `immutability` rule bans a top-level function) became `private enum TeeBytes`, and a literal `2` in a comparison (`no_magic_numbers` allows only `0`, `1`, `-1`, `100`) became `expected.count`.
    - periphery could not run here: it wants `.build/debug/index/store`, and this checkout has no index store. `FrameTeeTransport` is internal and the test target references it, so it is not an unreferenced declaration, and no `// periphery:ignore` was added.

    Not done here, on purpose: nothing wires the tee to `--frames`. That is ^3cat35c, and `SharedOptions.frames` waits for it.
  timestamp: 2026-09-04T14:13:10.705363+00:00
- actor: claude-code
  id: 01m1pc8ekj5npt5609e49fxavp
  text: |
    ### implement — changed
    - evidence: 2 new files — Sources/acp-client/FrameTeeTransport.swift, Tests/FoundationModelsACPClientTests/FrameTeeTransportTests.swift. `swift test`: 119 tests in 7 suites passed, 0 failures. `swift build --build-tests`: 0 warnings. All 6 acceptance rows and all 4 test rows are covered and ticked.
    - next: /review
  timestamp: 2026-09-04T14:13:14.482383+00:00
- actor: claude-code
  id: 01m1pca5pwv3qww7gnt89f0wd8
  text: |-
    ### test — green
    - evidence: swift package clean && swift test — 119 passed, 0 failed, 0 skipped, 0 warnings; swift build --product acp-client — clean, 0 warnings
    - next: proceed to review
  timestamp: 2026-09-04T14:14:10.908324+00:00
- actor: claude-code
  id: 01m1pcfyccvn8d6289fxbsyv3s
  text: |
    ### review — clean
    - scope: `review sha 8628783~1..8628783` — the diffs only. 2 files reviewed: `Sources/acp-client/FrameTeeTransport.swift`, `Tests/FoundationModelsACPClientTests/FrameTeeTransportTests.swift`. 6 `.kanban/` files skipped by `.reviewignore`.
    - evidence: zero new findings. counts: findings 0, confirmed 0, refuted 0, attempted 7, failed 0.
    - prior findings: none. All acceptance and test items were already checked.
    - next: task moved to `done`. The `--frames` wiring on RunCommand stays with ^3cat35c.
  timestamp: 2026-09-04T14:17:20.012121+00:00
- actor: claude-code
  id: 01m1pcgds84aqcty49m95rgffp
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files (Sources/acp-client/FrameTeeTransport.swift, Tests/FoundationModelsACPClientTests/FrameTeeTransportTests.swift); all 10 rows met
    - test: green — `swift package clean && swift test`, 119 passed, 0 failed, 0 skipped, 0 warnings; `swift build --product acp-client` clean
    - commit: 8628783 feat(acp-client): tee ndJSON frames to a sink for --frames
    - review: clean — zero new findings, 7 validators, task moved to done

    Carried forward for ^3cat35c: the tee is built and unit-tested but not wired. That task wraps the AgentProcess transport in FrameTeeTransport when --frames is given, with the sink pointed at stderr. The direction marks are pinned as `<< ` inbound and `>> ` outbound, with `[incomplete] ` for an unterminated tail.
  timestamp: 2026-09-04T14:17:35.784996+00:00
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
position_column: done
position_ordinal: '9080'
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

- [x] The inner transport's bytes reach the consumer unchanged, byte for byte.
- [x] A message split across three chunks is written to the sink one time, as
      one whole line.
- [x] Two messages inside one chunk are written as two lines.
- [x] An outbound write is written to the sink and reaches the inner
      transport.
- [x] The sink sees each line with its direction mark, and the two marks
      differ.
- [x] A trailing partial line at end of stream is reported as incomplete, and
      is not silently dropped.

## Tests

- [x] New `Tests/FoundationModelsACPClientTests/FrameTeeTransportTests.swift`.
      The tests drive `FrameTeeTransport` over a fake in-memory
      `ACPTransport`, with no process spawn. One test per acceptance row
      above.
- [x] One test feeds a chunk that splits a multi-byte UTF-8 codepoint across
      the boundary and asserts the forwarded bytes are unchanged and the
      emitted line is correct.
- [x] One test asserts the tee preserves order: inbound lines reach the sink in
      arrival order.
- [x] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
