---
assignees:
- claude-code
position_column: todo
position_ordinal: '9380'
title: 'Model: two concurrent resumeSession calls of one session share one replay state'
---
## What
Found during ^6np8vdv (2026-10-03). `ConnectionModel.resumeSession(_:)` does not serialize the `session/resume` requests of one session. When a caller starts a second resume of an open session while the first resume of the same session is still in flight:
- the second `beginReplay(replayFrom:)` resets the transcript of the shared model during the first replay;
- the outgoing-request subscription of the second replay replays the start of the first request, so the marker of the first request can end the second replay;
- the failure path of the first call (`endRunningReplayAsFailure()`) ends the replay of the second call.

The fix of ^6np8vdv (match the marker by the id of a request that started during the replay) is exact only for resumes of one session that run one after the other.

## Proposed approach
Serialize `resumeSession(_:)` per session id in `ConnectionModel`: a second call for the same session waits until the first call returned or threw, then runs. For a session id that is not open yet, the second call then finds the model that the first call registered.

## Acceptance Criteria
- [ ] Two concurrent `resumeSession` calls of one session give one model, and each replay ends only at the marker of its own request.
- [ ] A cancelled first call does not end the replay of the second call.

## Tests
- [ ] A test in `Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift` that starts two resumes of one session at the same time with a held answer gate, and checks the replay state with events (gates, HoldableTaskExecutor), never fixed sleeps.

## Workflow
- Use `/tdd`.