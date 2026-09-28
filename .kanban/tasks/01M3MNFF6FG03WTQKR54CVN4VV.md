---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mtwfs9770aybbaac7f8t94
  text: |-
    ### Note from swissarmyhammer-05 (2026-09-28): facts about TelemetryTestSupport
    - `TelemetryCapture` gives the metrics factory through the task-local `withMetricsFactory`. A metric that is made before the first capture does not go to the capture. Do not make the counters or the timer as `static let`. Make them for each call, or read the factory for each call.
    - A test must not call `LoggingSystem.bootstrap` itself; the capture bootstraps logging one time.
  timestamp: 2026-09-28T20:21:45.897868+00:00
depends_on:
- 01M3MNEZJAMMC2X6TE1YHZDF4K
position_column: todo
position_ordinal: '8280'
title: 'OTel C: record request count, request duration and request errors by ACP method'
---
## What

Part C of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). The library uses only the `Metrics` API (swift-metrics). The `acp-client` executable bootstraps the backend (task B).

After task A, every ACP request that the client sends goes through `ClientRequestSpan.run` in `Sources/FoundationModelsACPClient/Telemetry/ClientRequestSpan.swift`. This task adds the metrics in that one place, so each host that uses the helper gets them.

- [ ] In `ClientRequestSpan.run`: increment a request `Counter`, record the duration in a `Timer` (swift-metrics `Timer`, nanoseconds, or `Recorder` in seconds; follow the OpenTelemetry `rpc.client.duration` convention if it fits and document the choice), and increment an error `Counter` when `send` throws. Use the metric names from `ACPClientTelemetry.MetricName` (task D1; add them there if D1 did not).
- [ ] Dimensions: the ACP method name, and for errors the `RequestError` code (or `connection` for a `ConnectionError`, `cancelled` for a `CancellationError`). Rule 4: no session id (high cardinality), no prompt text, no error message text.
- [ ] Let a caller give an explicit `MetricsFactory` (default `MetricsSystem.factory`) so that a test can capture without a global bootstrap.
- [ ] Doc comments in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] One successful `session/prompt` gives request count 1 and one duration sample with dimension method = `session/prompt`, and no error count.
- [ ] A refused `session/close` gives an error count of 1 with the method and the error code as dimensions.
- [ ] No metric dimension holds a session id or any content.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Telemetry/ClientRequestMetricsTests.swift`: drive `AgentSession` and `TurnRunner` against `ScriptedStubAgent` over `InMemoryTransport.pair()`, capture metrics with `TelemetryCapture` from FoundationModelsExtras `TelemetryTestSupport` (OTel B ^z6jqd9g), and check the three criteria above. Use the stub's `closeSessionError` for the error case.
- [ ] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`. #otel