---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m738gxk07tnpb1wvppbwyzzb
  text: |-
    Research done. Discoveries:
    - `ClientModelExtensionContext.connectionState` is `@MainActor` only. The `_sah/graphql/*` handlers run in the read loop and must not hop to the main actor. Plan: an internal `nonisolated` accessor of the context for a `Sendable` connection state. A `@MainActor` class is `Sendable`, so the SAH state can be a `@MainActor @Observable` class with a `nonisolated let subscriptions: SAHGraphQLSubscriptions` (the `Mutex` table stays).
    - `didInitialize(_:state:)` gets no logger, but the `_meta.sah` diagnostic and the "left out the endpoint" diagnostic must go to the connection logger (tests assert them). `registerHandlers` runs one time after `makeConnectionState()` and before the connection opens, and its context has `connectionLogger`. Plan: `registerHandlers` gives the connection logger to the state, in a `Mutex` slot, before `didInitialize` can run.
    - The protocol has no empty default for `SessionState`. Plan: mirror `EmptyExtensionConnectionState` with `EmptyExtensionSessionState` and a constrained default of `makeSessionState(for:)`.
    - `ConnectionModel.sah` and `graphQLEndpoints` become computed reads of `extensionState(SAHGraphQLExtension.self)`. `openedExtensions` is observed and the state is `@Observable`, so observation still reports the change. A new connect makes a new state, so the reset at connect is automatic.
    - The close task in `connect` and `connectionDidClose` both call `OpenedExtensions.didClose()`, which runs one time; the SAH `didClose` calls `closeAll()` there.
  timestamp: 2026-11-10T17:36:34.400237+00:00
- actor: claude-code
  id: 01m739acz61sn67de06y3rws5j
  text: |-
    Implementation landed (TDD: the new test failed to compile with "cannot find 'SAHGraphQLExtension' in scope", then passed).
    - What did not work: an internal `nonisolated` accessor on `ClientModelExtensionContext` for a `Sendable` connection state. The compiler refuses it: "main actor-isolated property 'value' can not be referenced from a nonisolated context" (`MainActorHolder.value`). A logger slot that `registerHandlers` fills later breaks the rule "No stored property waits for a later method to fill it in", so I did not use one either.
    - Design used: the model makes a new `SAHGraphQLExtension(connectionLogger:)` for each connect (`BuiltInClientModelExtensions.extensions(connectionLogger:)`). The extension holds a new `SAHGraphQLSubscriptions` table and gives the table and the logger to the connection state it makes. The handlers use the table directly, in the read loop, with no main-actor hop. `ConnectionModel.extensions` became `hostExtensions`; each connect puts the built-ins first. No public API of the extension point changed.
    - New `EmptyExtensionSessionState` with a constrained default of `makeSessionState(for:)`, the same pattern as `EmptyExtensionConnectionState`.
    - Discovery: a race that was already in the code makes `aReplayFromTheStartAfterAnOverflowClearsTheMissedUpdatesMark` and `moreUpdatesThanTheBufferBeforeTheAnswerMarkMissedUpdates` fail now and then in the full run (one time each in two runs; then 6 of 6 full runs passed; the baseline passed 3 of 3). I recorded it as task ^epvfb (01M738V7VQC4565PA7VDFEPVFB, #flaky).
  timestamp: 2026-11-10T17:50:29.350878+00:00
- actor: claude-code
  id: 01m739aszz72j4y93tgmzkz7n4
  text: 'Correction to the comment before: the short id of the flaky-test task is ^dfepvfb (01M738V7VQC4565PA7VDFEPVFB), not ^epvfb.'
  timestamp: 2026-11-10T17:50:42.687178+00:00
- actor: claude-code
  id: 01m73a106hxhcbs7fnk4z3ac9h
  text: |-
    ### implement — changed
    - evidence: 8 files. New: Sources/FoundationModelsACPClient/GraphQL/SAHGraphQLExtension.swift. Changed: GraphQL/ConnectionGraphQLBackend.swift, GraphQL/SAHGraphQLSubscriptions.swift, Model/ClientModelExtension.swift, Model/ConnectionModel.swift, Model/ConnectionModel+Initialize.swift, Model/ModelClient.swift, FoundationModelsACPClient.docc/WritingAClientModelExtension.md, Tests/.../Model/ClientModelExtensionTests.swift (1 new test). `swift build`: clean. `swift test`: 863/863 passed in each of the last 6 full runs. 2 earlier full runs each had 1 failure from the race of ^dfepvfb, which was already in the code. `swift test --package-path IntegrationTests`: 23/23 passed in the last 2 full runs. 2 earlier full runs had `aKilledAgentResumesTheNestedRunWithItsTree` over its 120 s limit, the same kind of fault as 01M737WW16; I recorded it there. No existing assertion changed.
    - next: /review. The task stays in doing.
  timestamp: 2026-11-10T18:02:49.937161+00:00
- actor: claude-code
  id: 01m73avt7wqeqx10x83gqb6sp7
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (4f95d2f): 0 findings (confirmed 0, refuted 0, attempted 7, failed 0). 8 files reviewed. 10 .kanban files ignored. The docc WritingAClientModelExtension.md file has no validator.
    - next: none. The task is in done.
  timestamp: 2026-11-10T18:17:28.572263+00:00
- actor: claude-code
  id: 01m73awpef0gp677ntr11r9r0c
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 9 files (1 new)
    - test: green — swift test 863/863 x3; IntegrationTests 2 of 3 runs pass, 1 failure aHotResumeKeepsTheRunningChildRunning, which also fails 1 of 3 at HEAD (ACPAgent ^4273b5t, ACPClient 01M737WW16)
    - commit: 4f95d2f (pushed)
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-10T18:17:57.455678+00:00
depends_on:
- 01M73027HMPC6MQ49AQ9QHD8D7
- 01M7301R14HFNZGPCXSBQJT8CS
position_column: done
position_ordinal: ffab80
title: 'ACPC-4: move the SAH GraphQL tunnel (SAHGraphQLSubscriptions and _meta.sah) onto the extension point'
---
## What
Prove the connection part of ACPC-4 with the GraphQL tunnel (ACPC-6: "the client gets the `_sah/graphql/*` notifications through the extension point"). After this task, `ModelClient` has no GraphQL code.

Make these changes:
- [x] New `Sources/FoundationModelsACPClient/GraphQL/SAHGraphQLExtension.swift`: a `ClientModelExtension`. Its connection state holds the `SAHGraphQLSubscriptions` table of the connection and the `SAH.InitializeMeta?` of the connection.
  - `registerHandlers` registers `_sah/graphql/next`, `_sah/graphql/complete` and `_sah/graphql/error` (the code of `SAHGraphQLSubscriptions.extensionHandlers`).
  - `didInitialize` reads `_meta.sah` (the code that task 01M7301R14HFNZGPCXSBQJT8CS put in `ConnectionModel+Initialize.swift`).
  - `didClose` calls `closeAll()`.
- [x] `ConnectionModel` registers this extension as a built-in, as the other built-ins.
- [x] `Model/ModelClient.swift`: remove `graphQLSubscriptions` and the special case in `extensionHandlers`. Remove `ConnectionModel.graphQLSubscriptions`. `ConnectionModel.graphQLRoute()` (`GraphQL/ConnectionGraphQLBackend.swift`) reads the table from the extension state.
- [x] `ConnectionModel.sah` and `ConnectionModel.graphQLEndpoints` stay public, and read the extension state.
- [x] Update the doc comment of `connect(over:logger:bufferLimits:client:)`: a wrapping `Client` must give the `extensionHandlers` of the router, which now serve each registered extension.

## Acceptance Criteria
- [x] `ModelClient.swift` has no reference to `SAHGraphQLSubscriptions`.
- [x] Each stream of `SAHGraphQLClient.subscribe` ends with `SAHGraphQLError.connectionClosed` when the connection closes, as today.
- [x] The public API of `SAHGraphQLClient`, `SAHGraphQLEndpoint`, `ConnectionModel.sah` and `ConnectionModel.graphQLEndpoints` does not change.
- [x] All existing tests pass with no change of their assertions.

## Tests
- [x] `Tests/FoundationModelsACPClientTests/GraphQL/SAHGraphQLClientConnectionTests.swift`, `SAHGraphQLEndpointTests.swift` and `Model/ConnectionModelInitializeTests.swift` stay green with no change to the assertions.
- [x] Add one test to `ClientModelExtensionTests.swift`: a host extension and the SAH extension both serve their notifications on one connection.
- [x] Run `swift test` → all pass, and `swift test --package-path IntegrationTests` → all pass (the `graphql-tunnel-server` tests).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1