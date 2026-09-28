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
- actor: claude-code
  id: 01m3n531z46qrfydm0rkghvw0z
  text: |-
    ### Research
    - `ClientRequestSpan.run` calls `send` in the private `outcome(of:meta:in:)`. That is the one place to measure the duration and to see the error.
    - FoundationModelsExtras has the same pattern for tool calls: `ExtrasTelemetry.recordToolCall` makes the `Counter` and the `Metrics.Timer` at call time and records `Duration` from `ContinuousClock`. This task follows that pattern.
    - swift-metrics: `Counter(label:dimensions:factory:)` and `Timer(label:dimensions:factory:)` take an explicit factory. `MetricsSystem.factory` gives the task-local factory of `withMetricsFactory` first.
    - swift-otel exports a swift-metrics `Timer` as a duration histogram. That is the shape of the OpenTelemetry `rpc.client.duration` metric.
    - `TestMetrics` (MetricsTestKit) gives `expectCounter(_:_:)`, `expectTimer(_:_:)`, `counters`, `timers`. Extras declares `MetricsTestKit` as a direct test dependency; this package must do the same to import it.
    - `ConnectionError` has the cases `closed` and `timedOut`. `RequestError` is `ACPError`; `code.wireValue` is an `Int`.
    - `TracedSessionHarness` is private in `ClientRequestSpanTests.swift`. The new metrics tests need it, so it moves to a shared test file.
  timestamp: 2026-09-28T23:20:06.884087+00:00
- actor: claude-code
  id: 01m3n5tnf2m0w0z2t1v21re8w4
  text: |-
    ### Implementation notes
    - `ClientRequestSpan.run` has a new parameter `metricsFactory: any MetricsFactory = MetricsSystem.factory`. The default argument is read at call time, so the task-local factory of `TelemetryCapture` reaches it. The change is additive: all callers use the default.
    - A private `RequestMetrics` struct in `ClientRequestSpan` makes the `Counter`, the `Metrics.Timer` and the error `Counter` for each call. `outcome(of:meta:in:metrics:)` measures the duration with `ContinuousClock` around `send`.
    - Error code values: `String(RequestError.code.wireValue)`, or the new vocabulary `ACPClientTelemetry.ErrorCodeValue` (`connection`, `cancelled`, `other`). `other` is for an error that is none of the three types; the card did not name it, but each error needs one value.
    - `TracedSessionHarness` and `tracedPromptText` moved from `ClientRequestSpanTests.swift` to the shared file `Tests/FoundationModelsACPClientTests/Telemetry/TracedSessionHarness.swift`, so both telemetry test files use one harness.
    - `Package.swift`: the test target now declares `MetricsTestKit` (swift-metrics), as FoundationModelsExtras does, because the tests import it.
    - A closure that only throws cannot give the generic `Output` of `run`. The test writes `{ _ -> Void in throw failure }`.
    - Environment: each SwiftPM run writes "failed loading cached manifest ... disk I/O error" warnings. They come from the SwiftPM manifest cache on this machine, not from the code.
  timestamp: 2026-09-28T23:33:00.514493+00:00
- actor: claude-code
  id: 01m3n5trrmq39h9z5ayctxqqt7
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPClient/Telemetry/ClientRequestSpan.swift, Sources/FoundationModelsACPClient/Telemetry/ACPClientTelemetry.swift, Package.swift, Tests/FoundationModelsACPClientTests/Telemetry/ClientRequestMetricsTests.swift (new), Tests/FoundationModelsACPClientTests/Telemetry/TracedSessionHarness.swift (new), Tests/FoundationModelsACPClientTests/Telemetry/ClientRequestSpanTests.swift. RED seen first (missingMetric on each new test). `swift test --filter 'FoundationModelsACPClientTests\.(ClientRequestMetricsTests|ClientRequestSpanTests)'`: 12 tests passed. `swift test --parallel`: 253 tests in 25 suites passed. `swift test --package-path IntegrationTests`: 97 tests in 14 suites passed.
    - next: /review
  timestamp: 2026-09-28T23:33:03.892004+00:00
- actor: claude-code
  id: 01m3n62hccw5z8qp8q07stg129
  text: |-
    ### test — green
    - evidence: `swift test --parallel` — 253 tests, 25 suites, 0 failures, 0 skipped, exit code 0. `swift test --package-path IntegrationTests` — 97 tests, 14 suites, 0 failures, 0 skipped, exit code 0. No compiler warnings from this package's code in either run. SwiftPM printed "disk I/O error" manifest-cache warnings for dependency checkouts on both runs; these are machine noise, not code warnings, and did not count against the result.
    - next: send the task to review.
  timestamp: 2026-09-28T23:37:18.476074+00:00
depends_on:
- 01M3MNEZJAMMC2X6TE1YHZDF4K
position_column: doing
position_ordinal: '80'
title: 'OTel C: record request count, request duration and request errors by ACP method'
---
## What

Part C of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). The library uses only the `Metrics` API (swift-metrics). The `acp-client` executable bootstraps the backend (task B).

After task A, every ACP request that the client sends goes through `ClientRequestSpan.run` in `Sources/FoundationModelsACPClient/Telemetry/ClientRequestSpan.swift`. This task adds the metrics in that one place, so each host that uses the helper gets them.

- [x] In `ClientRequestSpan.run`: increment a request `Counter`, record the duration in a `Timer` (swift-metrics `Timer`, nanoseconds, or `Recorder` in seconds; follow the OpenTelemetry `rpc.client.duration` convention if it fits and document the choice), and increment an error `Counter` when `send` throws. Use the metric names from `ACPClientTelemetry.MetricName` (task D1; add them there if D1 did not).
- [x] Dimensions: the ACP method name, and for errors the `RequestError` code (or `connection` for a `ConnectionError`, `cancelled` for a `CancellationError`). Rule 4: no session id (high cardinality), no prompt text, no error message text.
- [x] Let a caller give an explicit `MetricsFactory` (default `MetricsSystem.factory`) so that a test can capture without a global bootstrap.
- [x] Doc comments in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] One successful `session/prompt` gives request count 1 and one duration sample with dimension method = `session/prompt`, and no error count.
- [x] A refused `session/close` gives an error count of 1 with the method and the error code as dimensions.
- [x] No metric dimension holds a session id or any content.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Telemetry/ClientRequestMetricsTests.swift`: drive `AgentSession` and `TurnRunner` against `ScriptedStubAgent` over `InMemoryTransport.pair()`, capture metrics with `TelemetryCapture` from FoundationModelsExtras `TelemetryTestSupport` (OTel B ^z6jqd9g), and check the three criteria above. Use the stub's `closeSessionError` for the error case.
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`. #otel