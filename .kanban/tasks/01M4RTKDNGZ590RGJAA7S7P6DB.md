---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4rvnjfc3kerx0btcsb4x986
  text: |-
    Research done.
    - `openSessions` is declared in `ConnectionModel.swift`. The direct readers are `session(for:)`, `register(_:)`, `unregister(_:)`, `closeOpenSessions()`, `deleteSession(_:)` in `ConnectionModel+List.swift`, `resumeInTurn(_:)` in `ConnectionModel+Sessions.swift`, and `completeElicitation(elicitationId:)` in `ConnectionModel+Elicitation.swift`.
    - The only test that reads `openSessions.keys` is `aRegisteredSessionIsOpen` in `ConnectionModelTests.swift`. The other tests read only `openSessions.isEmpty`.
    - `SessionModel` is `@MainActor @Observable`. `MCPServerItem` shows the pattern for an `Identifiable` main-actor class: a `nonisolated let` key and a `nonisolated var id`.
    - `Array.keepingLastOfEachID()` from ^jgnxmkf works on a full list. `register(_:)` adds one model at a time, so the index gives the position directly. The helper does not fit the single insert without a linear rebuild.
  timestamp: 2026-10-12T20:08:07.404145+00:00
- actor: claude-code
  id: 01m4rvydsxtb8avkjqcazmyt94
  text: |-
    Implementation landed (TDD: RED was a compile failure of the new tests on the dictionary; GREEN after the change).
    - `SessionModel` is `Identifiable`. `sessionId` is now `nonisolated let`, and `id` is a `nonisolated var`, the same pattern as `MCPServerItem`.
    - `ConnectionModel.openSessions` is `[SessionModel]`. A private `@ObservationIgnored openSessionPositions: [SessionId: Int]` holds the position of each model. `register(_:)` replaces in position or appends; `unregister(_:)` removes and renumbers the later positions; `closeOpenSessions()` empties both.
    - Callers: `completeElicitation` iterates the list; `deleteSession` and `resumeInTurn` use `session(for:)`. In `resumeInTurn` the call is `self.session(for:)`, because a local `let session` later in the same scope shadows the method.
    - `Array.keepingLastOfEachID()` from ^jgnxmkf is not used: it rebuilds a full list, and `register(_:)` adds one model, so the index gives the position directly.
    - Test support: `ScriptedStubAgent` gets `newSessionIds:` (each `session/new` answer takes the next id, then falls back to the script session), forwarded by `SessionFactoryFixtures.connect`. A shared `Array.identities` (`[ObjectIdentifier]`) in `SessionModelFixtures.swift` compares model identity.
    - What did not work: `#expect(list.elementsEqual(other, by: ===))` gives a "result unused" warning inside the `#expect` macro expansion, and `#expect(list.allSatisfy(\.isClosed))` does not compile (rethrows in the macro). Use `identities ==` and `map(\.isClosed) == [...]`.
  timestamp: 2026-10-12T20:12:57.533731+00:00
- actor: claude-code
  id: 01m4rvygdcm8cxpdd79j7p0vhe
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsACPClient/Model/SessionModel.swift, Model/ConnectionModel.swift, Model/ConnectionModel+Elicitation.swift, Model/ConnectionModel+List.swift, Model/ConnectionModel+Sessions.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelTests.swift, Model/ConnectionModelSessionTests.swift, Model/SessionModelFixtures.swift, ScriptedStubAgent.swift; `swift test` 514 tests in 40 suites passed, 0 failures, only warning is the accepted MLX "missing creator for mutated node" (^zws9qzt)
    - next: /review
  timestamp: 2026-10-12T20:13:00.204208+00:00
- actor: claude-code
  id: 01m4rvzyhbh6eqvrwhycskef6w
  text: |-
    ### test — green
    - evidence: swift test — 514 tests in 40 suites passed, 0 failed, 0 skipped. Only warning: the accepted MLX "missing creator for mutated node" warning (task ^zws9qzt). No compiler warnings.
    - next: review
  timestamp: 2026-10-12T20:13:47.435101+00:00
- actor: claude-code
  id: 01m4rw0j8a5s5kdmn1etbcpxtr
  text: |-
    ### commit — changed
    - evidence: b8620a0 feat(model)!: make openSessions an ordered list of Identifiable SessionModel (sha before the amend that adds this comment; the amend changes the sha)
    - next: review
  timestamp: 2026-10-12T20:14:07.626500+00:00
- actor: claude-code
  id: 01m4rw30zqkwxhysp97esh3k2c
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (8cc5afe). 0 findings, 0 confirmed, 0 refuted. 14 of 14 validator runs completed, 0 failed. 9 files reviewed. 4 .kanban files were not reviewed because of .reviewignore.
    - next: none. The task is in done.
  timestamp: 2026-10-12T20:15:28.247791+00:00
- actor: claude-code
  id: 01m4rw37r9am8a278dnk0sz86r
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 9 files
    - test: green — swift test, 514 passed, 0 failed
    - commit: 8cc5afe
    - review: clean — 0 findings
  timestamp: 2026-10-12T20:15:35.177199+00:00
position_column: done
position_ordinal: ee80
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
- [x] `SessionModel` is `Identifiable` and `id == sessionId`.
- [x] `openSessions` is `[SessionModel]` in registration order.
- [x] A second `register` of the same id replaces the model in its position, and the count does not change.
- [x] `unregister` keeps the order of the other models.
- [x] `session(for:)` uses the index.
- [x] A connection close empties the list and the index.

## Tests
- Add tests in `ConnectionModelSessionTests.swift`: two `newSession` calls give two models in call order; `resumeSession` of an open session does not add a model; `close(_:)` of the first model keeps the second model; the close of the connection empties the list.
- Add a test for the duplicate rule through `register(_:)` directly.
- Run `swift test`. All tests must pass.