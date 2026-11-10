---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73116473vqhbremyqjv9tv9
  text: 'Do this task first. TestudoApp ^az14ds4 (APP-16) waits for it. When it is pushed, send the commit to testudoapp-75 before the commits of the other step1 tasks. D176 (2026-11-10) replaces the import rule of D106: ACPClient can import GraphQL, so `import GraphQL` in `SAHGraphQLEndpoint.swift` stays.'
  timestamp: 2026-11-10T15:25:38.823277+00:00
- actor: claude-code
  id: 01m731pfjffegj6wgwrvk1zeq2
  text: 'Research: `SAH.InitializeMeta.extract(from:)` and `SAH.metaKey` ("sah") are public in FoundationModelsACP b6b265c (the resolved pin). The conversion `clientEndpoint(of:logger:)` is private static in `ConnectionGraphQLBackend`; it moves to a shared internal function. `graphQLEndpoints` is a stored property that the `didSet` of `sah` sets, so the diagnostic for an unknown scope comes one time, not at each read. `GraphQLTunnelStubAgent.initialize` throws method-not-found today; it must answer so a test can send `initialize`. `ScriptedStubAgent` gets an `initializeMeta` parameter for the model tests. The target has no `.docc` catalog; the DocC of the target is the type doc of `SAHGraphQLClient`.'
  timestamp: 2026-11-10T15:37:16.623534+00:00
- actor: claude-code
  id: 01m732wzftxxzw7wd63jj91t6h
  text: |-
    BLOCKER: the card conflicts with the agent as it is now. The card says that `endpoints()` gives the `_meta.sah` list and sends no request. But the real agent does not keep the two lists the same.

    I checked this on the wire with IntegrationTests/LiveAgentServer `graphql-tunnel-server`:
    - `initialize` `_meta.sah.graphql`: settings (server), snapshots (server).
    - `_sah/graphql/endpoints` before `session/new`: the same two.
    - `_sah/graphql/endpoints` after `session/new`: settings, snapshots, skills, agents, probe, kanban. The last four have the scope sessionFolder.

    So the `_meta.sah` list is a snapshot at `initialize`, and the session-folder endpoints of the host tools come only after a session opens. `swift test --package-path IntegrationTests --filter GraphQLTunnelTests` with this change: 3 of 10 fail (`endpointsListsTheProbeEndpointWithItsScope`, and the two kanban tests fail with `.unknownEndpoint(name: "kanban")` because `SAHGraphQLEndpoint` resolves through `endpoints()`). At HEAD all 10 pass. The doc comment of `advertisedSAHMeta()` in FoundationModelsACPAgent says "the same list as `_sah/graphql/endpoints`", but the behavior is different.

    A person must decide one of these:
    (a) Keep `ConnectionModel.sah` / `graphQLEndpoints` as observable data from `initialize`, but let `endpoints()` always send `_sah/graphql/endpoints`.
    (b) Correct FoundationModelsACPAgent so that `_meta.sah` lists every endpoint at `initialize`, including the session-folder endpoints of the host tools. Then this card works as written.
    (c) Some other rule, for example: `endpoints()` uses the `initialize` list only for server-scope endpoints.

    State of the tree (not committed): every item of the card is implemented, and all the unit tests pass. `swift test --filter "ConnectionModelInitializeTests|SAHGraphQLClientConnectionTests"` gives 55/55, `swift test` gives 816/816 in 68 suites, and `swift build` is clean (only the allowed mlx-swift_Cmlx "missing creator" warning).

    `swift format -i -r Sources Tests`: I ran it, but I did not keep the output. The repo has no `.swift-format` file. With the default settings, the tool rewrote 181 files to a 2-space indent. With a 4-space, 120-column setting it still changes 67 files at HEAD. I restored the tree to HEAD and applied my edits again. A check with the 4-space, 120-column setting shows no format change in my new lines.
  timestamp: 2026-11-10T15:58:18.106848+00:00
- actor: claude-code
  id: 01m732x3pb81k1qbvnww43k0p6
  text: |-
    ### implement — stuck
    - evidence: 8 files — Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift, Sources/FoundationModelsACPClient/GraphQL/ConnectionGraphQLBackend.swift, Sources/FoundationModelsACPClient/GraphQL/SAHGraphQLClient.swift, Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift, Tests/FoundationModelsACPClientTests/GraphQL/GraphQLTunnelStubAgent.swift, Tests/FoundationModelsACPClientTests/GraphQL/SAHGraphQLClientConnectionTests.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift. Filtered tests: 55/55 pass. swift test: 816/816 pass. IntegrationTests GraphQLTunnelTests: 3 of 10 fail with this change (10/10 at HEAD).
    - next: a person decides option (a), (b) or (c) of the blocker comment. The card stays in doing.
  timestamp: 2026-11-10T15:58:22.411446+00:00
- actor: claude-code
  id: 01m732xyeqnkcdqgrj2qmbzpe0
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 8 files changed (4 Sources, 4 Tests), not committed; swift test 816/816 pass; IntegrationTests GraphQLTunnelTests 3 of 10 fail with the change (10/10 at HEAD).
    - cause: `_meta.sah.graphql` of initialize lists only `settings` and `snapshots`. After `session/new`, `_sah/graphql/endpoints` also lists `skills`, `agents`, `probe`, `kanban`. Thus `endpoints()` cannot use the initialize list.
    - next: a decision from testudoapp-75: (a) `endpoints()` always sends the request, (b) correct ACPAgent, or (c) another rule. Recommendation: (a).
  timestamp: 2026-11-10T15:58:49.815210+00:00
- actor: claude-code
  id: 01m732ycb606zgh8t935wpn7m0
  text: |-
    ### decision (testudoapp-75) — option (a)
    This decision replaces these items of the description: "`endpoints()` gives the list of `sah` when `sah` is not `nil`, with no request" and the matching acceptance criterion and test.
    - The session endpoints (`skills`, `agents`, `kanban`, `probe`) come from the tools of a session, so they cannot be in `initialize`. The initialize list holds only the agent-level endpoints.
    - Keep `ConnectionModel.sah` and `ConnectionModel.graphQLEndpoints` as the observable initialize data.
    - `SAHGraphQLClient.endpoints()` always sends `_sah/graphql/endpoints`.
    - The doc comments must tell this clearly: `sah` / `graphQLEndpoints` = the agent endpoints at connect; `endpoints()` = the live list.
    - Tests: `endpoints()` sends the request also when `sah` is set. `GraphQLTunnelTests` in IntegrationTests must be 10/10.
  timestamp: 2026-11-10T15:59:04.038551+00:00
- actor: claude-code
  id: 01m7336fhm1556dhv5pj2ehwvq
  text: |-
    Option (a) is applied to the uncommitted work.
    - `ConnectionGraphQLBackend.endpoints()` always sends `_sah/graphql/endpoints`. I removed the short-circuit and the `advertisedEndpoints` field of `SAHGraphQLRoute`. `graphQLRoute()` is again as it was at HEAD.
    - `ConnectionModel.sah` and `graphQLEndpoints` stay as observable initialize data. Their doc comments tell that they hold the agent-level endpoints at connect, and that `SAHGraphQLClient.endpoints()` gives the live list, which also has the session endpoints. The type doc of `SAHGraphQLClient` and the doc of `endpoints()` tell the same.
    - The conversion from wire endpoints to client endpoints is still one shared function (`SAHGraphQLClient.Endpoint.clientEndpoints(of:logger:)`). `graphQLEndpoints` and `endpoints()` both use it.
    - Test: `endpointsGivesTheListOfTheInitializeAnswerAndSendsNoRequest` is now `endpointsWithASAHObjectSendsTheRequestAndGivesTheLiveList`. With `sah` set, it expects a `_sah/graphql/endpoints` frame and the list of the request, not the list of initialize. Before the source change, the test failed for the expected reason (2 issues).
    - Format: I did not run `swift format -i` over the tree. I ran it with a 4-space, 120-column setting on copies of my 8 files. Each line that it changes was in HEAD before, and none of my added lines changes.
  timestamp: 2026-11-10T16:03:29.460473+00:00
- actor: claude-code
  id: 01m7336jzz2as2tkb9gy6mkk2y
  text: |-
    ### implement — changed
    - evidence: 8 files: Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Model/ConnectionModel+Initialize.swift, GraphQL/ConnectionGraphQLBackend.swift, GraphQL/SAHGraphQLClient.swift, Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift, GraphQL/GraphQLTunnelStubAgent.swift, GraphQL/SAHGraphQLClientConnectionTests.swift, Model/ConnectionModelInitializeTests.swift. Results: `swift build` is clean (only the allowed mlx-swift_Cmlx warning). `swift test` passes 816/816 in 68 suites. `swift test --package-path IntegrationTests --filter GraphQLTunnelTests` passes 10/10.
    - next: /review. The card stays in doing, and nothing is committed. The description still has the old item and acceptance criterion about "no request". Decision comment 01m732ycb606zgh8t935wpn7m0 replaces them.
  timestamp: 2026-11-10T16:03:32.991332+00:00
position_column: doing
position_ordinal: '80'
title: ConnectionModel reads the SAH endpoint list from _meta.sah of initialize, and SAHGraphQLClient.endpoints() uses it
---
## What
ACPC-6 gap. The agent sends `SAH.InitializeMeta` in `_meta.sah` of the `initialize` response (FoundationModelsACPAgent `Agent/Initialization.swift:201`). The client does not read it today. `SAHGraphQLClient.endpoints()` over a connection always sends `_sah/graphql/endpoints`.

Make these changes:
- [ ] `Sources/FoundationModelsACPClient/Model/ConnectionModel.swift`: add the observable property `public internal(set) var sah: SAH.InitializeMeta?`. `nil` tells that the agent has no SAH extensions. `connect(over:logger:bufferLimits:client:)` sets it to `nil`, as it does for `initializeResponse`.
- [ ] `Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift`: in `initialize(_:)`, set `sah = SAH.InitializeMeta.extract(from: response.meta)`. When `_meta.sah` is present but is not a valid object, log one diagnostic to `connectionLogger` and set `nil`.
- [ ] Add the observable `public var graphQLEndpoints: [SAHGraphQLClient.Endpoint]` (derived from `sah`). Use the same conversion as `ConnectionGraphQLBackend.clientEndpoint(of:logger:)` (`GraphQL/ConnectionGraphQLBackend.swift`), so an endpoint with an unknown scope is left out with one diagnostic. Move that conversion to one shared function; do not copy it.
- [ ] `GraphQL/ConnectionGraphQLBackend.swift`: `endpoints()` gives the list of `sah` when `sah` is not `nil`, with no request. When `sah` is `nil` (no `initialize` yet, or an agent with no `_meta.sah`), it sends `_sah/graphql/endpoints` as today.
- [ ] Update the doc comments of `SAHGraphQLClient.endpoints()` and the DocC of the target.

`SAHGraphQLEndpoint` imports `GraphQL` for `Map` only. This task does not change that.

## Acceptance Criteria
- [ ] After `initialize` with `_meta.sah`, `ConnectionModel.sah` and `ConnectionModel.graphQLEndpoints` hold the list of the agent, and observation reports the change.
- [ ] After `initialize` with no `_meta.sah`, `sah` is `nil` and `graphQLEndpoints` is empty.
- [ ] A new `connect` sets `sah` to `nil`.
- [ ] `SAHGraphQLClient(connection:).endpoints()` gives the initialize list and sends no `_sah/graphql/endpoints` frame when `sah` is not `nil`.
- [ ] With no `_meta.sah`, `endpoints()` sends `_sah/graphql/endpoints` and gives its result.
- [ ] `swift build` gives no new warnings.

## Tests
- [ ] `Tests/FoundationModelsACPClientTests/Model/ConnectionModelInitializeTests.swift`: initialize with `_meta.sah` (two endpoints, one with an unknown scope) → `sah` set, `graphQLEndpoints` has one endpoint, one diagnostic; initialize with no `_meta.sah` → `nil`; malformed `_meta.sah` → `nil` and one diagnostic; reconnect → `nil`.
- [ ] `Tests/FoundationModelsACPClientTests/GraphQL/SAHGraphQLClientConnectionTests.swift`: extend `GraphQLTunnelStubAgent` to send `_meta.sah` in its initialize response, and record the frames (`FrameRecordingTransport`). Assert that `endpoints()` sends no `_sah/graphql/endpoints` frame and gives the meta list. A second test with no meta asserts the request is sent.
- [ ] Run `swift test --filter "ConnectionModelInitializeTests|SAHGraphQLClientConnectionTests"` → all pass. Then `swift test` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1