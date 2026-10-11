---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4p0q7sa16czfqvnb6w0p286
  text: |-
    Research done.
    - `ClientRequestSpan.withRequestSpan` sets `rpc.method` on each span, so the replay span does not use it. The replay span calls `TracedCall.run` directly (kind `.internal`), as the card says.
    - `TracedCall.run` sets the error status and `error.type` when the body throws. It never records the error object or its description, so a refused request obeys rule 4.
    - The marker of the response can end the replay BEFORE `waitForReplayEnd()` is called. Thus `waitForReplayEnd()` must return a kept result (`replaySucceeded`) when no replay runs, and not a constant.
    - A replay whose subscription ends before the marker, with a successful response: attach a hand-made subscription (`SessionModelFixtures.handMadeSubscription()`) to the open model and finish it while the agent holds its answer (`resumeSessionGate`).
    - Live updates after the replay: the stub sends its `script` during `session/prompt`, after the resume returned.
  timestamp: 2026-10-11T17:38:41.578650+00:00
- actor: claude-code
  id: 01m4p18fn6fjsk2txnmhtdk3vn
  text: |-
    Implementation landed (TDD: RED was a compile failure on the missing `SpanName.replay`, `ReplayFromValue`, `replayedUpdateCount`, and the `Bool` result of `waitForReplayEnd()`).
    - `ConnectionModel.replay(_:into:over:)` now opens the replay span with `TracedCall.run` (kind `.internal`) and calls the old body, renamed `runReplay`, which returns the result of `waitForReplayEnd()`. A `defer` sets `acp.replay.update_count` on each exit path. A `false` result sets the error status. A refused request throws out of the body, so `TracedCall` sets the error status and `error.type`, and never the error object.
    - `SessionModel.replaySucceeded` keeps the result of `endReplay(succeeded:)`. `waitForReplayEnd()` returns it when no replay runs, because the marker can end the replay before the call.
    - `ReplaySpanFixtures.connect` is a new private fixture in `ReplaySpanTests`. `SessionFactoryFixtures` in `ConnectionModelSessionTests` is private and has no prompt `script`, so the live-update test cannot use it.
    - Added `aWaitAfterTheReplayEndedGivesTheResultOfThatReplay` to `SessionModelStreamTests`, and `replaySpans` to `RequestTelemetryQueries`.
    - No ARCHITECTURE.md exists.

    ### implement — changed
    - evidence: `swift test --filter "ReplaySpan|ACPClientTelemetryVocabulary|ConnectionModelSession|SessionModelStream"`: 103 tests in 4 suites passed. `swift test`: 466 tests in 37 suites passed. The one warning is the accepted SwiftPM MLX "missing creator for mutated node" warning (task 01M3Z8M7YKRR5TQ5NRPZWS9QZT). 8 files: Sources/FoundationModelsACPClient/Telemetry/ACPClientTelemetry.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift, Sources/FoundationModelsACPClient/Model/SessionModel.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Stream.swift, Tests/FoundationModelsACPClientTests/Telemetry/ReplaySpanTests.swift (new), Tests/FoundationModelsACPClientTests/Telemetry/RequestTelemetryQueries.swift, Tests/FoundationModelsACPClientTests/Telemetry/ACPClientTelemetryVocabularyTests.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift
    - next: /review
  timestamp: 2026-10-11T17:48:06.694625+00:00
- actor: claude-code
  id: 01m4p1bjmddxaeah8q6fy20mp9
  text: |-
    ### test — green
    - evidence: swift test — 466 tests in 37 suites passed, 0 failed, 0 skipped. No build warning except the known SwiftPM MLX "missing creator for mutated node" warning (task 01M3Z8M7YKRR5TQ5NRPZWS9QZT).
    - next: review. No code changed in this step. No commit made.
  timestamp: 2026-10-11T17:49:48.045159+00:00
- actor: claude-code
  id: 01m4p1k266psd367mhn0248e97
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (d44487d). 1 finding (1 confirmed, 0 refuted): Tests/FoundationModelsACPClientTests/Telemetry/RequestTelemetryQueries.swift:34 (reuse/reuse).
    - next: /implement the open item in "## Review Findings (2026-10-11 12:50)". The task stays in review.
  timestamp: 2026-10-11T17:53:53.350608+00:00
- actor: claude-code
  id: 01m4p1kdeddjg8ghjjv84qbk0s
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 8 files
    - test: green — swift test, 466 passed
    - commit: d44487d
    - review: findings — Tests/FoundationModelsACPClientTests/Telemetry/RequestTelemetryQueries.swift:34
  timestamp: 2026-10-11T17:54:04.877337+00:00
- actor: claude-code
  id: 01m4p1s1wy5xp07j600ycb55jw
  text: |-
    Review finding fixed. `RequestTelemetryQueries.swift` now has one private `spans(named:)` helper that holds the only name filter. `agentRequestSpans` and `replaySpans` call it. `spans(named:of:)` calls it and adds the method filter. No other `operationName ==` filter stays in the file. This is a refactor with no change in behavior, so no new test is necessary. The existing telemetry tests cover each query. Note: `dump validators` wrote a rules file of 754K characters, which is too large to read in one pass.

    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPClientTests/Telemetry/RequestTelemetryQueries.swift. `swift test`: 466 tests in 37 suites passed. The one warning is the accepted SwiftPM MLX "missing creator for mutated node" warning.
    - next: /review
  timestamp: 2026-10-11T17:57:09.662063+00:00
- actor: claude-code
  id: 01m4p1vdamddnc137dnz2dbxq9
  text: |-
    ### test — green
    - evidence: swift test — 466 tests in 37 suites passed, 0 failed, 0 skipped. Only warning: the accepted SwiftPM MLX "missing creator for mutated node" (task 01M3Z8M7YKRR5TQ5NRPZWS9QZT).
    - next: review
  timestamp: 2026-10-11T17:58:26.900636+00:00
- actor: claude-code
  id: 01m4p2034efpn5j6kaz7eg0h9y
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (da58700). 0 findings (7 validator runs, 0 failed). The prior finding at RequestTelemetryQueries.swift:34 is checked.
    - next: none. The task is in done.
  timestamp: 2026-10-11T18:01:00.302202+00:00
- actor: claude-code
  id: 01m4p20e0z0201vrfkpk4mhm7g
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file
    - test: green — swift test, 466 passed
    - commit: da58700
    - review: clean — 0 findings; task in done
  timestamp: 2026-10-11T18:01:11.455817+00:00
depends_on:
- 01M4NX8Q4WFYJMHPCGWG6RJXDC
position_column: done
position_ordinal: ea80
title: Open a replay span around each session/resume, with the replayed update count
---
## What

Open one internal span for each replay of a `session/resume`. The span starts before the request goes out and ends when the model has applied the last replayed update. The `session/resume` client request span becomes its child, because the request opens in the context of the replay span (`sendRecordingAuth` gives no `parent`, so it uses `.current`). Thus a trace shows the replay, the request, and the number of updates that the agent sent again.

Spec rule (`ResumeSessionRequest.replayFrom` in `acp-v2.json`): "Omitted or `null` both mean the Agent should resume without replaying previous conversation history. Replay cursors are inclusive ... `{ \"type\": \"start\" }` means the Agent should replay all retained conversation history before responding." Thus the replayed updates come before the response, and the marker of the response ends the replay (`SessionModel+Stream.swift:124`).

Files:
- Modify: `Sources/FoundationModelsACPClient/Telemetry/ACPClientTelemetry.swift`
- Modify: `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift`: in `replay(_:into:over:)` (line 180), wrap the code from `session.beginReplay(replayFrom:)` (line 189) to `session.waitForReplayEnd()` (line 201) in `TracedCall.run` with kind `.internal`.
- Modify: `Sources/FoundationModelsACPClient/Model/SessionModel.swift`: declare `@ObservationIgnored var replayedUpdateCount = 0`, internal, beside `replayRequests` (line 156). It must not be observed, because it changes for each update. In `apply(_:)` (line 312), after `guard !isClosed`, add 1 only when `replayPhase` is `.replaying(from: .some)`. A resume with no `replayFrom` asks for no replay, so it counts nothing.
- Modify: `Sources/FoundationModelsACPClient/Model/SessionModel+Stream.swift`: `beginReplay` sets `replayedUpdateCount = 0`. Make `waitForReplayEnd()` return `Bool`: `true` when the replay ended with success. `endReplay(succeeded:)` keeps that result, so a caller that waits gets it. Update the existing callers.
- New: `Tests/FoundationModelsACPClientTests/Telemetry/ReplaySpanTests.swift`

Names to add to `ACPClientTelemetry` (each one `public`):
- `SpanName.replay = prefix + "replay"`
- `AttributeKey.replayFrom = "acp.replay.from"`, with the values `start`, `none` and `other` in `enum ReplayFromValue`. A `ReplayFrom.unknown` gives `other`, so the set of values stays small and fixed (rule 4).
- `AttributeKey.replayUpdateCount = "acp.replay.update_count"`

Span content:
- Attributes: `session.id`, `acp.replay.from`, and `acp.replay.update_count`. Set the count on each exit path: success, a refused request, and a replay that ends as a failure.
- A refused request, or a replay that ends as a failure (`waitForReplayEnd()` gives `false`, for example because the subscription ended before the marker), sets the error status. Do not record the error object, as `ClientRequestSpan.recordFailure` (`ClientRequestSpan.swift:277`) does not. Rule 4 keeps the error message text out of telemetry.
- A resume with no `replayFrom` still gets the span, with `acp.replay.from = none` and a count of 0. Thus each resume has the same shape.
- Do not add a span or an event for each replayed update.

## Acceptance Criteria
- [x] A `session/resume` with `replayFrom = start` gives one span with name `FoundationModelsACPClient.replay`, kind `.internal`, `session.id`, `acp.replay.from = start`, and `acp.replay.update_count` equal to the number of updates that the stub sent before its response.
- [x] The `FoundationModelsACPClient.request` span with `rpc.method = session/resume` is a child of the replay span.
- [x] A resume with no `replayFrom` gives `acp.replay.from = none` and a count of 0, also when the stub sends updates before its response.
- [x] A resume that the agent refuses gives the error status and a count. The span holds no error message.
- [x] A replay whose subscription ends before the marker gives the error status.
- [x] Two resumes of one session, one after the other (`resumeTurns`), give two replay spans with their own counts.
- [x] Live updates that come after the replay ended do not change the count.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Telemetry/ReplaySpanTests.swift`: drive the real `ConnectionModel` with `ScriptedStubAgent` (its `resumeSessionScript`) over `InMemoryTransport.pair()` in a `TelemetryCapture`. Cover each criterion above.
- [x] Update the existing tests of `waitForReplayEnd()` in `Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift` for the `Bool` result.
- [x] Update `Tests/FoundationModelsACPClientTests/Telemetry/ACPClientTelemetryVocabularyTests.swift` for the new names.
- [x] Run `swift test --filter "ReplaySpan|ACPClientTelemetryVocabulary|ConnectionModelSession|SessionModelStream"`. All tests pass.
- [x] Run `swift test`. All tests pass and the build has no warnings.

## Workflow
- Use `/tdd`: write the failing tests first, then write the code that makes them pass. #telemetry

## Review Findings (2026-10-11 12:50)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 8 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

- [x] `Tests/FoundationModelsACPClientTests/Telemetry/RequestTelemetryQueries.swift:34` `reuse/reuse` — The new `replaySpans` property repeats the body of the existing `agentRequestSpans` property, `spans.filter { $0.operationName == <name> }`, as a third copy. The file already holds a `spans(named:of:)` helper, but it also filters on the method attribute, so a shared name-only filter is missing. The change adds a near-copy instead of extending the existing code, so the filter logic now lives in three places. Add one private helper, for example `spans(named:)`, that returns `spans.filter { $0.operationName == spanName }`. Use it in `replaySpans` and `agentRequestSpans`, and let `spans(named:of:)` call it and add the method filter. This keeps one filter implementation and changes no test result.
