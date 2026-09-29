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
- actor: claude-code
  id: 01m3n6ggfhjtnjrpahjvwn34fy
  text: |-
    ### Research (implement)
    - `TurnRunner.run()` calls `AgentSession.openSession()` itself. Thus `TracedSessionHarness.runWholeSession()` (initialize, run, closeSession) drives all four requests. A second, separate `openSession()` call would open a second subscription for the same session, so the test does not do that.
    - `AgentSession` and `TurnRunner` take no tracer, logger or metrics factory. The capture gives them through its task-local tracer and metrics factory and through the logging bootstrap. `ClientRequestSpan.run` makes its `Logger` and its metrics at call time, so each record goes to the capture.
    - `ScriptedStubAgent` has no permission request and no prompt refusal. The test needs both. Plan: add `permissionRequest: RequestPermissionRequest?` and `promptError: RequestError?` to the stub, and `prompt`, `cwd`, `permissionRequest`, `promptError` to `TracedSessionHarness` (all with defaults, so the current callers do not change).
    - ACP v2 has no `toolCall` session update case. `toolCallUpdate(ToolCallUpdate)` holds `title`, `rawInput` and `rawOutput`. A permission request holds `title` and a `.toolCall(ToolCallPermissionSubject)` subject with its own tool title.
    - `RequestError` is `ACPError`; `RequestError(code:message:data:)` makes an error with a fixture message.
    - `TerminalOutput` and `DecliningClient` write to the terminal sink, not to swift-log. They are not telemetry.
  timestamp: 2026-09-28T23:44:56.306002+00:00
- actor: claude-code
  id: 01m3n72tqwgdsw9vg68xd2emeb
  text: |-
    ### Implementation landed
    - New `Tests/FoundationModelsACPClientTests/Telemetry/ContentSafetyTests.swift`, suite "content safety", two tests:
      - "an answered turn puts no content into telemetry": `TelemetryCapture.run(forbidding:)` over `TracedSessionHarness.runWholeSession()` (initialize, `TurnRunner.run()` which calls `openSession()`, `closeSession`). Forbidden: prompt, agent message chunk, tool call title, raw input, raw output, permission request title, permission tool title, `cwd` marker.
      - "a refused turn puts no error text into telemetry": the stub refuses `session/prompt` with `RequestError(code: .internalError, message: <fixture>, data: {detail: <fixture>})`. The test expects that exact error from `runner.run()`, then closes and tears down.
      - Both tests check that the capture saw at least one span, one log record and one metric.
    - `ScriptedStubAgent` got `permissionRequest` and `promptError`. `TracedSessionHarness` got `prompt`, `cwd`, `permissionRequest` and `promptError`. All have defaults, so the current callers did not change.
    - TDD: RED was a compile failure (the harness had no such parameters). GREEN after the stub and harness change.

    ### Proof that the test can fail (temporary, reverted with `git checkout -- Sources/`, not committed)
    - Change 1: prompt text as `sessionId` of the prompt request, `cwd` as `sessionId` of `session/new`, an extra `Logger.info` of the session id in `ClientRequestSpan.run`, the error message as a span attribute in `recordFailure`, and the error message as the `errorCode` metric dimension. Result: 14 issues. Each of the four place kinds failed: span attribute (`request.temporary.leak`, `request.session.id`), log message (`log info: TEMPORARY LEAK ...`), log metadata (`session.id`), metric dimension (`rpc.jsonrpc.error_code`).
    - Change 2: `ClientRequestSpan.run` returned `send(meta)` at once. Result: 6 issues, "The capture saw no span / no log record / no metric" in each test.
    - After the revert, `git status` shows no change under `Sources/`.

    ### Note
    - Each `swift test` prints SwiftPM `failed loading/storing cached manifest ... disk I/O error` warnings. They come from the SwiftPM manifest cache of the machine, not from the source. There is no compiler warning.
  timestamp: 2026-09-28T23:54:56.636892+00:00
- actor: claude-code
  id: 01m3n72x79wpwcf9bjn1k7cntg
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsACPClientTests/Telemetry/ContentSafetyTests.swift (new), Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift, Tests/FoundationModelsACPClientTests/Telemetry/TracedSessionHarness.swift. `swift test --filter 'FoundationModelsACPClientTests\.ContentSafetyTests'`: 2 tests passed. `swift test --parallel`: 255 tests in 26 suites passed. `swift test --package-path IntegrationTests`: 97 tests in 14 suites passed.
    - next: /review
  timestamp: 2026-09-28T23:54:59.177224+00:00
- actor: claude-code
  id: 01m3n77rktr58kn881we505erf
  text: |-
    ### test — green
    - evidence: `swift test --parallel` — 255 tests in 26 suites passed, 0 failures, 0 warnings, 0 skipped. `swift test --package-path IntegrationTests` — 97 tests in 14 suites passed, 0 failures, 0 warnings, 0 skipped. No SwiftPM manifest-cache disk I/O warnings appeared in either run.
    - next: ready for review.
  timestamp: 2026-09-28T23:57:38.298940+00:00
- actor: claude-code
  id: 01m3n78p6742cjaj8jrxfegwh0
  text: |-
    ### commit — changed
    - evidence: ddd7f85 test(telemetry): add the content-safety test for spans, logs, and metrics
    - next: proceed to review
  timestamp: 2026-09-28T23:58:08.583433+00:00
- actor: claude-code
  id: 01m3n7dex6gh4a4gwcx4dvjpry
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (ddd7f85). 0 findings (confirmed 0, refuted 0, attempted 7, failed 0). The engine reviewed 3 Swift test files. An ignore rule (.reviewignore) excluded 4 .kanban files. The task had no prior review findings.
    - next: The task moved to done.
  timestamp: 2026-09-29T00:00:44.966016+00:00
- actor: claude-code
  id: 01m3n7dntatw841vn6trrcn2x7
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files (ContentSafetyTests.swift new, ScriptedStubAgent.swift, TracedSessionHarness.swift)
    - test: green — swift test --parallel 255 passed; IntegrationTests 97 passed
    - commit: ddd7f85
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-09-29T00:00:52.042841+00:00
depends_on:
- 01M3MNEZJAMMC2X6TE1YHZDF4K
- 01M3MNFF6FG03WTQKR54CVN4VV
position_column: done
position_ordinal: b780
title: 'OTel D2: add the content-safety test for spans, logs and metrics of a full acp-client turn'
---
## What

Part D (second half) of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rule 4: no prompt text, response text, tool arguments, tool output or file content in a span attribute, a log message, a log metadata value or a metric dimension. Rule 5: each package has a content-safety test that uses the shared `TelemetryCapture` helper from the FoundationModelsExtras `TelemetryTestSupport` product (Extras OTel B, ^z6jqd9g). Task D1 adds that product to the test target.

After tasks A and C, every request goes through `ClientRequestSpan.run` (`Sources/FoundationModelsACPClient/Telemetry/ClientRequestSpan.swift`), which writes spans, one "enter" log record and metrics. This test is the guard for all of them, and for all future telemetry in this package.

- [x] New `Tests/FoundationModelsACPClientTests/Telemetry/ContentSafetyTests.swift`. In `TelemetryCapture.run(forbidding:)`, drive one full turn: `AgentSession.initialize()`, `openSession()`, `TurnRunner.run()`, `closeSession(_:)`, against `ScriptedStubAgent` over `InMemoryTransport.pair()`. Use distinct fixture strings: a prompt text, an agent message chunk text, a tool call title and raw input and output (`SessionUpdate` fixtures in `Tests/FoundationModelsACPClientTests/SessionUpdateFixtures.swift`), a permission request tool title, and a `cwd` path content marker. Give the capture's tracer, logger and metrics factory to the code under test.
- [x] A second case: a turn that the agent refuses with a `RequestError` whose message holds a fixture string. The error message must not reach any telemetry.
- [x] A check that the capture saw at least one span, one log record and one metric, so the test cannot pass on empty output.

## Acceptance Criteria
- [x] The test passes on the code of tasks A and C.
- [x] The test fails if a fixture string is put into any span attribute, log message, log metadata value or metric dimension (prove it once with a temporary change during the work; do not commit it).
- [x] The test fails if the capture records no span, no log record or no metric.

## Tests
- [x] `Tests/FoundationModelsACPClientTests/Telemetry/ContentSafetyTests.swift` as above.
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.
- Blocked also by FoundationModelsExtras OTel B (^z6jqd9g, 01M3MN8N9P4RPET2V5JZ6JQD9G). #otel