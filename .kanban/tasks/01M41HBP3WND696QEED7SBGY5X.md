---
assignees:
- claude-code
position_column: todo
position_ordinal: '9580'
title: 'Model: newSession must not register a session after its connection closed'
---
## What
`ConnectionModel.newSession(_:)` in `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift` awaits the `session/new` response. Then it subscribes, makes the model, and registers it. The close of the connection runs in a separate main-actor task (`connectionDidClose`). If the response resolves and the connection closes before the `newSession` continuation runs, `closeOpenSessions()` runs first. Then `newSession` registers a new open model for a closed connection. That model stays in `openSessions` with `isClosed == false`, and a later `connect(over:)` does not remove it.

- [ ] After the await, compare the local connection with `self.connection`. When they differ, close the new model (`markClosed()`), do not register it, and throw `ConnectionError.closed`.
- [ ] Apply the same check in `resumeSession(_:)` when task ^6np8vdv adds it.

## Acceptance Criteria
- [ ] A `session/new` whose connection closes before the continuation runs leaves `openSessions` empty and throws `ConnectionError.closed`.

## Tests
- [ ] Add a test in `Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift` that holds the agent answer with an `UpdateGate`, closes the connection after the answer is on the wire, and checks the result. Use events to wait, never fixed sleeps.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.