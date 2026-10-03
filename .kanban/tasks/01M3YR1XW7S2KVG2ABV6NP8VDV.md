---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yrgqvvswp24zpek9st4byj
  text: 'Buffer bound (from foundationmodelsacp-c7, 2026-10-02): the limits (1024 updates per session, 64 sessions) are parameters of the `ClientSideConnection` initializer. For the overflow test, give a small limit when the test creates the connection. If `ConnectionModel.connect(over:...)` makes the connection, add an optional pass-through parameter for the limits (default = upstream default). The exact parameter name is in the gate task 81s5j74 comments.'
  timestamp: 2026-10-02T16:52:48.123247+00:00
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