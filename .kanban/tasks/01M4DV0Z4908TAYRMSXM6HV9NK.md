---
comments:
- actor: claude-code
  id: 01m4dy25r3jsxgg90m8s28b039
  text: |-
    Research done.
    - `RequestError.init(reporting:)` is in `Sources/FoundationModelsACPClient/Model/SessionModel+Prompt.swift`. It is internal. `SessionModel.prompt` and `ConnectionModel+Initialize.swift` (the auth failure reason) call it.
    - `SessionModel` has a private `appendError(_ failure: RequestError)`, and a public `appendError(code:message:data:)`.
    - The `SessionModel` initializer is internal. A test file that uses a plain `import FoundationModelsACPClient` (no `@testable`) can still use the test-module helpers `SessionModelFixtures.immediateModel()` and `TranscriptEntry.error`. Thus such a file proves that the API is public: if the API is internal, the file does not compile.
    - Plan: make the initializer public, and change the private `appendError(_:)` to a public `appendError(reporting:)`. Both options of the card then exist, with one implementation.
  timestamp: 2026-10-08T14:18:18.755819+00:00
- actor: claude-code
  id: 01m4dy8jqz195fewwaad0x00f4
  text: |-
    Implementation done.
    - `RequestError.init(reporting:)` is now public. Its doc comment gives the text and the `connectionError` data of each `ConnectionError` case, and tells a host to use it.
    - New public `SessionModel.appendError(reporting:)`. It replaces the private `appendError(_ failure: RequestError)`. `prompt(_:meta:)` now calls it. Thus there is one implementation.
    - `connectionErrorDataKey` and `ConnectionError.reportMessage` stay private. The card does not ask for them.
    - New test file `Tests/FoundationModelsACPClientTests/Model/RequestErrorReportingTests.swift`. It uses a plain import (no `@testable`). RED: the file did not compile ("incorrect argument label ... expected 'from:'", "extra argument 'reporting'"). GREEN: 4 of 4 pass.
    - Full run: `swift test` gives 594 tests in 52 suites, all pass. `swift build --build-tests --package-path IntegrationTests` completes. The only warning is the accepted mlx-swift "missing creator for mutated node" warning (^zws9qzt).

    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPClient/Model/SessionModel+Prompt.swift, Tests/FoundationModelsACPClientTests/Model/RequestErrorReportingTests.swift (new); `swift test` 594/594 pass; IntegrationTests build complete
    - next: /review
  timestamp: 2026-10-08T14:21:48.671656+00:00
- actor: claude-code
  id: 01m4dybma42mdpqjcm5je2a67h
  text: |-
    ### test — green
    - evidence: swift test — 594 tests in 52 suites passed, 0 failed, 0 skipped. swift build --build-tests --package-path IntegrationTests — Build complete.
    - note: only the accepted mlx-swift SwiftPM warning "missing creator for mutated node" showed (task ^zws9qzt). No warning comes from a file of this package.
    - next: review
  timestamp: 2026-10-08T14:23:28.580845+00:00
- actor: claude-code
  id: 01m4dyf402gfa2zncsq3mv0f0m
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (74fc2df). 2 files reviewed. 0 findings, 0 confirmed, 0 refuted (7 attempted, 0 failed). 4 .kanban files not reviewed (.reviewignore).
    - next: none. The task moved to done.
  timestamp: 2026-10-08T14:25:22.946692+00:00
- actor: claude-code
  id: 01m4dyfae85yg4g280ge30w0pw
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files
    - test: green — swift test, 594 passed, 0 failed, 0 skipped
    - commit: 74fc2df
    - review: clean — 0 findings
  timestamp: 2026-10-08T14:25:29.544703+00:00
position_column: done
position_ordinal: e680
title: Make RequestError.init(reporting:) public
---
## What
Request from AgentViewKit (task ^ahfhekw there). `RequestError.init(reporting:)` in `Sources/FoundationModelsACPClient/Model/SessionModel+Prompt.swift` is internal. Thus AgentViewKit cannot call it. AgentViewKit has a copy of this initializer to add an error entry for a request that fails. The kit copy has no `ConnectionError` case. Thus for a closed connection or a time-out, the kit error entry shows `String(describing: error)`, not the client text ("The connection to the agent closed before the agent answered." and "The request timed out before the agent answered."), and it has no `connectionError` data key.

- [x] Make `RequestError.init(reporting:)` public, or give a public `SessionModel.appendError(reporting:)` that adds the error entry with the same text and data.
- [x] Document the public API.

## Acceptance Criteria
- [x] A host outside the client package can make the error entry for an error that a request gives, with the client text and data, with no copy of the client logic.

## Tests
- [x] A test calls the public API with a closed-connection error and a time-out error, and checks the text and the `connectionError` data key of the entry.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.