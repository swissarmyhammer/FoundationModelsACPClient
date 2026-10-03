---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yrgqvvswp24zpek9st4byj
  text: 'Buffer bound (from foundationmodelsacp-c7, 2026-10-02): the limits (1024 updates per session, 64 sessions) are parameters of the `ClientSideConnection` initializer. For the overflow test, give a small limit when the test creates the connection. If `ConnectionModel.connect(over:...)` makes the connection, add an optional pass-through parameter for the limits (default = upstream default). The exact parameter name is in the gate task 81s5j74 comments.'
  timestamp: 2026-10-02T16:52:48.123247+00:00
- actor: claude-code
  id: 01m417yqybb8spc68gr9y7nade
  text: 'RISK FROM ^ccdm82c (2026-10-03), must be handled in this task: replayed updates reach `SessionModel` through the asynchronous stream task of `attach(_:)`. The `session/resume` response can resume the caller before that task has applied every replayed update, so `endReplay(succeeded:)` can run on an incomplete transcript and `isReplaying` goes false too early. Required: `resumeSession` calls `endReplay` only after every update that the router yielded before the response has been applied. Find out from the upstream code (or ask foundationmodelsacp-c7) what order guarantee `ClientSideConnection` gives between the notifications of a session and the response of a request, and build an explicit barrier on it (for example a drain or sequence marker in the subscription path). Add a test: an agent that sends many replay updates and then answers `session/resume` at once; after `resumeSession` returns, the transcript holds every replayed entry and `isReplaying == false`.'
  timestamp: 2026-10-03T16:01:04.459105+00:00
- actor: claude-code
  id: 01m4180vrp9n24f0h989n3y2yr
  text: 'UPSTREAM ANSWER on the resume order (foundationmodelsacp-c7, 2026-10-03): when `resumeSession(_:)` returns, every `session/update` that came before the response on the wire is already YIELDED into the subscription stream, in wire order, with an unbounded buffer. But the consumer task may not have applied them yet, and `AsyncStream` has no "drained" query, so no exact barrier is possible from outside the stream. Proposed upstream fix (pending their user''s decision; we said yes): the subscription stream yields an enum with `.update(SessionUpdate)` and an in-band `.responseReceived(id:method:)` marker (also on failure) for each response to a client request that names this session. Then SessionModel calls `endReplay` when its consumer reads the marker of the `session/resume` request. WAIT for the final names from foundationmodelsacp-c7 before implementing the resume part of this task; if the marker is not on upstream main when this task starts, do Step 0: update the pin and check for it, and if it is missing, report stuck with "upstream marker not ready".'
  timestamp: 2026-10-03T16:02:13.910394+00:00
- actor: claude-code
  id: 01m4181bn0dy4c02jjt2hdsjm7
  text: 'UPSTREAM CARD (foundationmodelsacp-c7, 2026-10-03), NOT STARTED, names can change: the subscription stream will yield `.responseReceived(id: RequestId, method: String, outcome: .succeeded / .failed)`, one marker for each client request whose params name a sessionId, at the exact wire position of the response and before the caller resumes. It is also yielded with `.failed` for an error response, cancel, timeout, write failure and close (before the stream finishes), and buffered in order for a session with no subscriber. The deprecated `updates(for:)` keeps plain `SessionUpdate` and drops markers. This task waits for the final names and commit.'
  timestamp: 2026-10-03T16:02:30.176296+00:00
depends_on:
- 01M3YR1M92146TWJC24JGE1QVF
- 01M3YRB9RRT2GXY0Q47K0BRVV6
- 01M3YR107XV14K8J9F1HFGS4Y9
- 01M3YR0RQGPVCP3RV2MCCDM82C
position_column: todo
position_ordinal: '8780'
title: 'Model: ConnectionModel session factory — newSession, resumeSession, open sessions, close'
---
## What
Add the session factory to `ConnectionModel` in `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift`. Upstream API: `connection.subscribe(to:) -> SessionUpdateSubscription` (`updates`, `missedUpdates`); the router clears the buffer and the mark itself when `session/close` goes through the connection. Use the final names from gate task 81s5j74. The registry (`openSessions`, `register`, `unregister`) is in task jge1qvf; `requireCapability` is in task k0brvv6.

- [ ] `newSession(_ request: NewSessionRequest) async throws -> SessionModel`: send the request unchanged; as soon as the response is decoded, `subscribe(to:)` (the first subscriber takes the buffer and the overflow mark), make the model with the connection's cadence and clock, `attach`, `seed` from the response (`availableCommands`, `configOptions`), give it the request sender, `register` it.
- [ ] `resumeSession(_ request: ResumeSessionRequest) async throws -> SessionModel`: `requireCapability(canResumeSessions)`. For a new id: make the model and `subscribe(to:)` BEFORE the request is sent. For an id that is already open: reuse that model and its subscription (same instance). Then `beginReplay(replayFrom: request.replayFrom)` (it resets the transcript of a reused model), send, `endReplay(succeeded:)`, `seed`. On failure: end the replay; a new model is not registered; rethrow.
- [ ] `close(_ session: SessionModel) async throws`: `requireCapability(canCloseSessions)`; sends `session/close`; `unregister`; `markClosed()`. The model stays readable. If the capability is false, it throws `.unsupported` and the model stays open (callers that want a local close call `session.markClosed()`; acp-client does not need this, see task hvqk65a).

## Acceptance Criteria
- [ ] Updates that the agent sends between its `session/new` response and the attach are in the model (none lost).
- [ ] An agent that sends more than the buffer bound before its `session/new` response gives `hasMissedUpdates == true`.
- [ ] A response with no command list leaves `availableCommands == nil`; a response with a list seeds it.
- [ ] A resume replay goes into the model while `isReplaying == true`. A second resume of an open session returns the same instance with the same transcript (no doubled text), and a `.start` replay after an overflow clears `hasMissedUpdates`.
- [ ] After `close`, the model has `isClosed == true` and is not in `openSessions`.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift` over `InMemoryTransport.pair()` with `ScriptedStubAgent`: updates before the new-session response; overflow before the response (set a small bound if the router lets the connection configure it); seed with and without commands; a chunked replay done two times; resume after overflow; a failed resume; close; resume and close against an agent without the capability throw and the agent sees no request.
- [ ] `swift test --filter ConnectionModelSessionTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.