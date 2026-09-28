---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mtwj2r9fawtyt7b4qwg6bd
  text: |-
    ### Note from swissarmyhammer-05 (2026-09-28): facts about TelemetryTestSupport
    - `TelemetryCapture` gives the tracer and the metrics factory through the task-local `withTracer` and `withMetricsFactory`, and bootstraps logging one time only. The test must not call `LoggingSystem.bootstrap`.
    - A logger or a metric that is made before the first capture does not go to the capture. If the "at least one span, one log record and one metric" check fails, first look for a `static let` logger or metric in the code under test.
  timestamp: 2026-09-28T20:21:48.248378+00:00
depends_on:
- 01M3MNEZJAMMC2X6TE1YHZDF4K
- 01M3MNFF6FG03WTQKR54CVN4VV
position_column: todo
position_ordinal: '8580'
title: 'OTel D2: add the content-safety test for spans, logs and metrics of a full acp-client turn'
---
## What

Part D (second half) of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rule 4: no prompt text, response text, tool arguments, tool output or file content in a span attribute, a log message, a log metadata value or a metric dimension. Rule 5: each package has a content-safety test that uses the shared `TelemetryCapture` helper from the FoundationModelsExtras `TelemetryTestSupport` product (Extras OTel B, ^z6jqd9g). Task D1 adds that product to the test target.

After tasks A and C, every request goes through `ClientRequestSpan.run` (`Sources/FoundationModelsACPClient/Telemetry/ClientRequestSpan.swift`), which writes spans, one "enter" log record and metrics. This test is the guard for all of them, and for all future telemetry in this package.

- [ ] New `Tests/FoundationModelsACPClientTests/Telemetry/ContentSafetyTests.swift`. In `TelemetryCapture.run(forbidding:)`, drive one full turn: `AgentSession.initialize()`, `openSession()`, `TurnRunner.run()`, `closeSession(_:)`, against `ScriptedStubAgent` over `InMemoryTransport.pair()`. Use distinct fixture strings: a prompt text, an agent message chunk text, a tool call title and raw input and output (`SessionUpdate` fixtures in `Tests/FoundationModelsACPClientTests/SessionUpdateFixtures.swift`), a permission request tool title, and a `cwd` path content marker. Give the capture's tracer, logger and metrics factory to the code under test.
- [ ] A second case: a turn that the agent refuses with a `RequestError` whose message holds a fixture string. The error message must not reach any telemetry.
- [ ] A check that the capture saw at least one span, one log record and one metric, so the test cannot pass on empty output.

## Acceptance Criteria
- [ ] The test passes on the code of tasks A and C.
- [ ] The test fails if a fixture string is put into any span attribute, log message, log metadata value or metric dimension (prove it once with a temporary change during the work; do not commit it).
- [ ] The test fails if the capture records no span, no log record or no metric.

## Tests
- [ ] `Tests/FoundationModelsACPClientTests/Telemetry/ContentSafetyTests.swift` as above.
- [ ] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.
- Blocked also by FoundationModelsExtras OTel B (^z6jqd9g, 01M3MN8N9P4RPET2V5JZ6JQD9G). #otel