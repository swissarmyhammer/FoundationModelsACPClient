---
position_column: todo
position_ordinal: '8280'
title: Make RequestError.init(reporting:) public
---
## What
Request from AgentViewKit (task ^ahfhekw there). `RequestError.init(reporting:)` in `Sources/FoundationModelsACPClient/Model/SessionModel+Prompt.swift` is internal. Thus AgentViewKit cannot call it. AgentViewKit has a copy of this initializer to add an error entry for a request that fails. The kit copy has no `ConnectionError` case. Thus for a closed connection or a time-out, the kit error entry shows `String(describing: error)`, not the client text ("The connection to the agent closed before the agent answered." and "The request timed out before the agent answered."), and it has no `connectionError` data key.

- [ ] Make `RequestError.init(reporting:)` public, or give a public `SessionModel.appendError(reporting:)` that adds the error entry with the same text and data.
- [ ] Document the public API.

## Acceptance Criteria
- [ ] A host outside the client package can make the error entry for an error that a request gives, with the client text and data, with no copy of the client logic.

## Tests
- [ ] A test calls the public API with a closed-connection error and a time-out error, and checks the text and the `connectionError` data key of the entry.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.