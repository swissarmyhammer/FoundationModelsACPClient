---
assignees:
- claude-code
depends_on:
- 01M4NX8Q4WFYJMHPCGWG6RJXDC
position_column: todo
position_ordinal: '8280'
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
- [ ] A `session/resume` with `replayFrom = start` gives one span with name `FoundationModelsACPClient.replay`, kind `.internal`, `session.id`, `acp.replay.from = start`, and `acp.replay.update_count` equal to the number of updates that the stub sent before its response.
- [ ] The `FoundationModelsACPClient.request` span with `rpc.method = session/resume` is a child of the replay span.
- [ ] A resume with no `replayFrom` gives `acp.replay.from = none` and a count of 0, also when the stub sends updates before its response.
- [ ] A resume that the agent refuses gives the error status and a count. The span holds no error message.
- [ ] A replay whose subscription ends before the marker gives the error status.
- [ ] Two resumes of one session, one after the other (`resumeTurns`), give two replay spans with their own counts.
- [ ] Live updates that come after the replay ended do not change the count.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Telemetry/ReplaySpanTests.swift`: drive the real `ConnectionModel` with `ScriptedStubAgent` (its `resumeSessionScript`) over `InMemoryTransport.pair()` in a `TelemetryCapture`. Cover each criterion above.
- [ ] Update the existing tests of `waitForReplayEnd()` in `Tests/FoundationModelsACPClientTests/Model/SessionModelStreamTests.swift` for the `Bool` result.
- [ ] Update `Tests/FoundationModelsACPClientTests/Telemetry/ACPClientTelemetryVocabularyTests.swift` for the new names.
- [ ] Run `swift test --filter "ReplaySpan|ACPClientTelemetryVocabulary|ConnectionModelSession|SessionModelStream"`. All tests pass.
- [ ] Run `swift test`. All tests pass and the build has no warnings.

## Workflow
- Use `/tdd`: write the failing tests first, then write the code that makes them pass. #telemetry