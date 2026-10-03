---
assignees:
- claude-code
depends_on:
- 01M3YR1XW7S2KVG2ABV6NP8VDV
- 01M3YR27ERN3DKRHMA1C5TYWBR
- 01M3YRB9RRT2GXY0Q47K0BRVV6
position_column: todo
position_ordinal: 8f80
title: 'Telemetry: every request that the models send gets a client span, metrics, and trace _meta'
---
## What
Today `AcpClientCore` wraps each outbound request in `ClientRequestSpan.run` (`Sources/FoundationModelsACPClient/Telemetry/ClientRequestSpan.swift`), which opens the span, records the metrics, and puts the W3C trace context in `_meta`. With the new models, the models send the requests, so the models must do this. Decision: the spans go in `ConnectionModel` and in the real `SessionRequestSender`, not in callers.

- [ ] Add the new method names to `ClientRequestSpan.Method`: `session/resume`, `session/list`, `session/delete`, `session/set_config_option`, `auth/login`, `auth/logout` (keep `initialize`, `session/new`, `session/prompt`, `session/cancel`, `session/close`).
- [ ] Wrap each request in `ConnectionModel` (initialize, new, resume, list, close, delete, login, logout) and in the real `SessionRequestSender` (prompt, cancel, setConfigOption) with `ClientRequestSpan.run`. A `meta` that the caller gives is kept, and the trace context is added to it.
- [ ] `SessionModel.cancel(meta:)`: when the caller gives the trace parent of the prompt (acp-client does this), the `session/cancel` span uses it as its parent, as `TurnRunner` does now.
- [ ] No content of a prompt, a tool call, or a message goes into a span, a log, or a metric (the content-safety rule of the OTel design).

## Acceptance Criteria
- [ ] Each model request gives exactly one client span with the correct method name, and one count and one duration metric.
- [ ] The `_meta` of each request has the `traceparent` of its span.
- [ ] The content-safety check finds no prompt text in the captured telemetry.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Telemetry/ModelRequestSpanTests.swift` with the `TelemetryTestSupport` capture of `FoundationModelsExtras` and `MetricsTestKit`: one test per request method over `InMemoryTransport.pair()`; a cancel-parent test; a content-safety test.
- [ ] Existing `Tests/FoundationModelsACPClientTests/Telemetry/*` tests still pass.
- [ ] `swift test --filter Telemetry` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.