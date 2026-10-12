---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Make openSessions an ordered list of Identifiable SessionModel
---
## Goal
An MDI SwiftUI app must observe a list of session models, and open one window for each new model. The app must not compare dictionary keys.

## Change
- Make `SessionModel` conform to `Identifiable`, with `id` equal to `sessionId`.
- Change `ConnectionModel.openSessions` (`Sources/FoundationModelsACPClient/Model/ConnectionModel.swift:33`) from `[SessionId: SessionModel]` to `[SessionModel]`. Keep it observed and `public private(set)`.
- The order is the order of registration. `register(_:)` appends a new model to the end.
- Do not permit duplicates. If `register(_:)` gets a model with the id of a model that is already in the list, replace that model at its current position. Do not append it again.
- Keep a private `[SessionId: Int]` (or `[SessionId: SessionModel]`) index with `@ObservationIgnored`, so `session(for:)` and the duplicate check do not use a linear search. Make sure that the index agrees with the list after each `register`, `unregister` and `closeOpenSessions`.
- `unregister(_:)` removes the model and keeps the order of the other models.
- Update the internal callers: `ConnectionModel+Elicitation.swift:108` (`openSessions.values`), `ConnectionModel+List.swift:130`, `ConnectionModel+Sessions.swift:148`, `ConnectionModel.swift:300`. Use `session(for:)` for a lookup by id.
- Update the tests that read `openSessions.keys` (`ConnectionModelTests.swift:262`). `openSessions.isEmpty` still compiles.
- Update the doc comments that say "keyed by its session id".

## Do not
- Do not add a busy state, a turn state, or an event stream.

## Acceptance criteria
- [ ] `SessionModel` is `Identifiable` and `id == sessionId`.
- [ ] `openSessions` is `[SessionModel]` in registration order.
- [ ] A second `register` of the same id replaces the model in its position, and the count does not change.
- [ ] `unregister` keeps the order of the other models.
- [ ] `session(for:)` uses the index.
- [ ] A connection close empties the list and the index.

## Tests
- Add tests in `ConnectionModelSessionTests.swift`: two `newSession` calls give two models in call order; `resumeSession` of an open session does not add a model; `close(_:)` of the first model keeps the second model; the close of the connection empties the list.
- Add a test for the duplicate rule through `register(_:)` directly.
- Run `swift test`. All tests must pass.