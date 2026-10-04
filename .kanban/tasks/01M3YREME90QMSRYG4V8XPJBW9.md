---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m43d7vjq4c93tjfvq1wtn8cm
  text: |-
    Research (implement step):
    - ConnectionModel sends 8 requests straight on `ClientSideConnection` with no span: initialize, auth/login, auth/logout (+Initialize.swift), session/new, session/resume (in `replay`), session/close (+Sessions.swift), session/list (in `loadSessionPage`), session/delete (+List.swift). `ConnectionSessionRequestSender` sends prompt, cancel, set_config_option with no span.
    - Every request type of FoundationModelsACP has `public var meta: JSONValue?`, so one generic helper can wrap the caller's request, keep its `_meta`, and add the trace context. No per-method copy.
    - `ConnectionModel.WireMethod` (login, logout, listSessions, deleteSession) and `ScriptedStubAgent.setConfigOptionMethod` duplicate the wire names. The card puts these names in `ClientRequestSpan.Method`, so WireMethod goes away and its users (5 test files) use `ClientRequestSpan.Method`.
    - Cancel parent: there is no extractor in FoundationModelsExtras (only `SpanIdentity.injectedFields`; the `DictionaryExtractor` of TelemetryTestSupport is private and a test target). The library needs a small private `Extractor` over `[String: String]`, fed by `TraceContextMeta.extract(from:)`. The test gives the prompt traceparent that the stub agent received as the `meta` of `SessionModel.cancel(meta:)`.
    - Discovery for ^dennhyk: `SessionModel.prompt` opens its span inside the sender, so acp-client cannot read the prompt span context as `TurnRunner` does now (it records `ParentContext.current` inside the span closure). That task needs a way to get the traceparent of the sent prompt.
  timestamp: 2026-10-04T12:11:54.839181+00:00
- actor: claude-code
  id: 01m43dqdnmqga2zrb68xq67zbp
  text: |-
    ### implement — changed
    - evidence: RED: `swift test --filter ModelRequestSpanTests` failed with 49 issues (no span, no metric for each model request). GREEN: same filter passed (6 tests, 3 of them with 11 cases each). Full root `swift test`: 523 tests in 43 suites passed. `swift test --package-path IntegrationTests`: 103 tests in 14 suites passed. Build: only the accepted MLX "missing creator" warning and the `SessionUpdateAggregator` deprecations.
    - production: new `Sources/FoundationModelsACPClient/Telemetry/TracedClientMessage.swift` (protocol `TracedClientMessage` with the wire method and session of each of the 11 request types; `ClientRequestSpan.send(_:parent:through:)`, which keeps the caller `_meta` and adds the trace context through the existing `run`; `ClientRequestSpan.ParentContext(extractingFrom:)` for the cancel parent). `ClientRequestSpan.Method` gains listSessions, deleteSession, setConfigOption, login, logout. `ConnectionModel.WireMethod` is removed (it duplicated those names). ConnectionModel+Initialize/+Sessions/+List and `ConnectionSessionRequestSender` send each request through `ClientRequestSpan.send`; the cancel uses the `traceparent` of its `meta` as parent. `SessionModel.cancel(meta:)` doc updated.
    - tests: new `Telemetry/ModelRequestSpanTests.swift` (one span, one count and one duration, and the traceparent in `_meta`, for each of the 11 model requests over `InMemoryTransport.pair()`; caller meta kept; cancel-parent; content-safety). New shared `Telemetry/RequestTelemetryQueries.swift` (`requestSpans(of:)`, `expectEachSignal()`, `methodDimension`, `traceparentIdentity`); the private copies in ClientRequestSpanTests, ClientRequestMetricsTests and ContentSafetyTests now use it. `ScriptedStubAgent.receivedMeta(of:)` is the one filter; `ConnectedModel` and `TracedSessionHarness` forward to it. Test references to `WireMethod` and `setConfigOptionMethod` now use `ClientRequestSpan.Method`.
    - next: /review. Note for ^dennhyk recorded on that card (acp-client needs a way to get the prompt traceparent for the cancel).
  timestamp: 2026-10-04T12:20:24.884531+00:00
- actor: claude-code
  id: 01m43dvcan2fgy614qm1p31bxf
  text: |-
    ### test - green
    - evidence: swift build --build-tests (root) complete. swift test (root): 523 tests in 43 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests: 103 tests in 14 suites passed, 0 failed, 0 skipped. All commands used the given --scratch-path folders.
    - warnings: only the accepted SwiftPM warning "missing creator for mutated node" (MLX bundle). No other warning in the logs.
    - note: both builds were incremental (about 3 seconds), so the logs show only warnings from the changed targets that were built.
    - next: review
  timestamp: 2026-10-04T12:22:34.581084+00:00
- actor: claude-code
  id: 01m43dvy5yfr8y4n33kp021s8y
  text: |-
    ### commit — changed
    - evidence: local commit "feat(telemetry): trace every request that the models send" (sha is in git log; no push)
    - next: review
  timestamp: 2026-10-04T12:22:52.862235+00:00
depends_on:
- 01M3YR1XW7S2KVG2ABV6NP8VDV
- 01M3YR27ERN3DKRHMA1C5TYWBR
- 01M3YRB9RRT2GXY0Q47K0BRVV6
position_column: doing
position_ordinal: '80'
title: 'Telemetry: every request that the models send gets a client span, metrics, and trace _meta'
---
## What
Today `AcpClientCore` wraps each outbound request in `ClientRequestSpan.run` (`Sources/FoundationModelsACPClient/Telemetry/ClientRequestSpan.swift`), which opens the span, records the metrics, and puts the W3C trace context in `_meta`. With the new models, the models send the requests, so the models must do this. Decision: the spans go in `ConnectionModel` and in the real `SessionRequestSender`, not in callers.

- [x] Add the new method names to `ClientRequestSpan.Method`: `session/resume`, `session/list`, `session/delete`, `session/set_config_option`, `auth/login`, `auth/logout` (keep `initialize`, `session/new`, `session/prompt`, `session/cancel`, `session/close`).
- [x] Wrap each request in `ConnectionModel` (initialize, new, resume, list, close, delete, login, logout) and in the real `SessionRequestSender` (prompt, cancel, setConfigOption) with `ClientRequestSpan.run`. A `meta` that the caller gives is kept, and the trace context is added to it.
- [x] `SessionModel.cancel(meta:)`: when the caller gives the trace parent of the prompt (acp-client does this), the `session/cancel` span uses it as its parent, as `TurnRunner` does now.
- [x] No content of a prompt, a tool call, or a message goes into a span, a log, or a metric (the content-safety rule of the OTel design).

## Acceptance Criteria
- [x] Each model request gives exactly one client span with the correct method name, and one count and one duration metric.
- [x] The `_meta` of each request has the `traceparent` of its span.
- [x] The content-safety check finds no prompt text in the captured telemetry.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Telemetry/ModelRequestSpanTests.swift` with the `TelemetryTestSupport` capture of `FoundationModelsExtras` and `MetricsTestKit`: one test per request method over `InMemoryTransport.pair()`; a cancel-parent test; a content-safety test.
- [x] Existing `Tests/FoundationModelsACPClientTests/Telemetry/*` tests still pass.
- [x] `swift test --filter Telemetry` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.