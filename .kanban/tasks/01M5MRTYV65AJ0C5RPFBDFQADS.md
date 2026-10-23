---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5msqp7ygshpk7r14eybjtgs
  text: |-
    Research (implement step):
    - The wire types are in FoundationModelsACP: `SAH.GraphQL` (Sources/FoundationModelsACP/SAH/SAHGraphQL.swift, commit 270f9e3). The extension seam is also there (commit fb3c08d): `Client.extensionHandlers`, `ExtensionHandlers.registerNotification`, `ClientSideConnection.callExtensionMethod` and `sendExtensionNotification`. The local resolution of this package was 7890129, which has none of them. Package.resolved is in .gitignore, so `swift package update FoundationModelsACP` (now accd0a6) is a local step only; CI resolves main.
    - Server order (GraphQLTunnelSubscription.swift): the server starts the subscription task before it answers `_sah/graphql/subscribe`, so `_sah/graphql/next` can come before the subscribe response. The client must route the id before it sends subscribe.
    - Server: an unsubscribed or closed subscription sends no end message. An unknown endpoint gives one `_sah/graphql/error` (UNKNOWN_ENDPOINT). A subscription id that is in use gives an invalid-params RequestError.
    - The connection reads `Client.extensionHandlers` one time, when the factory returns. Thus ModelClient must serve the `_sah/graphql/next|complete|error` notifications, and route them to the subscriptions of the client.
    - IntegrationTests cannot link FoundationModelsACPAgent (the "Conflicting identity" warning). The real GraphQLTunnel must run in a server process of the LiveAgentServer package. `RoutedACPAgent.registerHostTools` is internal, so a test endpoint needs `@testable import FoundationModelsACPAgent` in that debug-built server. `ComposedAgent.compose(modelSource: .stub)` loads no model.
  timestamp: 2026-10-23T16:33:03.742116+00:00
- actor: claude-code
  id: 01m5mt5c18jzjd5zwdtb8h291c
  text: 'Unit side landed (TDD: RED was the missing init(connection:); GREEN 14/14 in SAHGraphQLClientConnectionTests). New: GraphQL/SAHGraphQLSubscriptions.swift (per-connection table, serves next/complete/error), GraphQL/ConnectionGraphQLBackend.swift (backend protocol, stub backend, connection backend, ConnectionModel.graphQLRoute()). ModelClient now gives extensionHandlers. ConnectionModel makes one table per connect and closes it at each close. The client routes the id before it sends subscribe; on a stopped iteration it waits for the subscribe answer and then sends unsubscribe (else the server can lose the unsubscribe, because the server runs each request in its own task but each notification in the read loop). Swift note: `#expect(throws:)` with an AsyncIterator in the closure does not compile (sending risks data race); use do/catch.'
  timestamp: 2026-10-23T16:40:32.040820+00:00
- actor: claude-code
  id: 01m5mtwq72brvkf9d3jjp5e0wz
  text: |-
    Integration side landed. IntegrationTests cannot link the agent, so the LiveAgentServer package got a second executable, `graphql-tunnel-server`: `ComposedAgent.compose(modelSource: .stub)` (no model load) plus a host tool with a small `probe` endpoint (scope sessionFolder; execute echoes the variables; subscribe gives N events then complete, or holds; a watcher stream reports each server-side cancel, so the unsubscribe test is event-driven). `registerHostTools` is internal in FoundationModelsACPAgent, so the server uses `@testable import FoundationModelsACPAgent`; this works because `swift build` builds debug with testability on. A public `registerHostTools` in the agent package would remove the @testable (sibling repo, not edited). To avoid copies, `LaunchArguments` and the home setup moved into a new `LiveAgentServerSupport` target that both servers use; `LiveAgentServerBuild` now takes the product name and starts the server; `IntegrationTemporaryDirectory` and `InitializeRequest.integrationTest(clientName:)` are shared by the two test files. Known T1 limit (commented in the test): the watcher wait in `aStoppedIterationStopsTheSubscriptionOnTheServer` has no failure event other than the close of the connection.

    ### implement — changed
    - evidence: `swift build` clean (only the allowed mlx-swift_Cmlx.bundle warning); `swift test` 684 tests in 56 suites passed; `swift test --package-path IntegrationTests --no-parallel` 7 tests in 2 suites passed (6 GraphQL + 1 live turn); `swift build` of IntegrationTests/LiveAgentServer clean. Files: Sources/FoundationModelsACPClient/GraphQL/{SAHGraphQLClient,SAHGraphQLSubscriptions,ConnectionGraphQLBackend}.swift, Sources/FoundationModelsACPClient/Model/{ConnectionModel,ModelClient}.swift, Tests/FoundationModelsACPClientTests/GraphQL/{GraphQLTunnelStubAgent,SAHGraphQLClientConnectionTests}.swift, IntegrationTests/Package.swift, IntegrationTests/LiveAgentServer/Package.swift, IntegrationTests/LiveAgentServer/Sources/{LiveAgentServerSupport/*,graphql-tunnel-server/*,live-agent-server/LiveAgentServer.swift}, IntegrationTests/Tests/.../{GraphQLTunnelTests,LiveAgentServerBuild,LiveAgentTurnTests}.swift, .github/workflows/ci.yml (comments only). Local only: FoundationModelsACP resolution moved 7890129 -> accd0a6 (Package.resolved is gitignored).
    - next: /review. After done: send the result to session kanbanviewkit-fb (last acceptance box).
  timestamp: 2026-10-23T16:53:17.154929+00:00
position_column: doing
position_ordinal: '80'
title: SAHGraphQLClient over a real ACP connection (ACPC-6)
---
## Source

Request from the KanbanViewKit session (../KanbanViewKit/plan.md §3.3, §7.3, §8).

## What

Today `SAHGraphQLClient` has only `init(stub:)` (Sources/FoundationModelsACPClient/GraphQL/SAHGraphQLClient.swift:110). Its doc comment says that a later initializer makes the client over an ACP connection. Add that initializer.

- Add a public initializer from a `ConnectionModel` (or from its client connection).
- `execute` sends `_sah/graphql/execute`.
- `subscribe` sends `_sah/graphql/subscribe`. It reads `_sah/graphql/next`, `_sah/graphql/complete` and `_sah/graphql/error` for its subscription id.
- When the caller stops the iteration, send `_sah/graphql/unsubscribe` (see the doc comment of `subscribe`).
- `endpoints()` sends `_sah/graphql/endpoints`.
- Update the type doc comment: remove the words "A later initializer".

## Ends of the subscribe stream (decided with the KanbanViewKit session)

KanbanViewKit `BoardModel` treats each end of the stream as missed updates (KanbanViewKit plan §3.3 step 4). It then sets `hasMissedUpdates` and resumes from its cursor.

- `_sah/graphql/complete` ends the stream with a normal finish. It does not throw.
- `_sah/graphql/error` throws `SAHGraphQLError.graphQL(_:)`.
- A closed connection throws `SAHGraphQLError.connectionClosed`.
- The client does not subscribe again by itself.
- Put this rule in the doc comment of `subscribe`.

## Tests

- Unit tests in the main package: execute and subscribe over a real in-process connection (`InMemoryTransport.pair()`) with a small test agent that answers the `_sah/graphql/*` methods. Test `next`, `complete` (normal finish), `error` (throws), a closed connection (throws), and `unsubscribe`.
- Integration tests in `IntegrationTests/` (the main package cannot link FoundationModelsACPAgent, because that package depends on this one): execute and subscribe against `GraphQLTunnel` of FoundationModelsACPAgent (../FoundationModelsACPAgent/Sources/FoundationModelsACPAgent/Agent/GraphQLTunnel.swift) with a small test endpoint.

## Acceptance

- [x] Public initializer over an ACP connection.
- [x] execute, subscribe, unsubscribe and endpoints use the `_sah/graphql/*` wire.
- [x] complete finishes the stream normally; error and a closed connection throw. The doc comment of `subscribe` states this rule.
- [x] Unit tests and integration tests pass. CI runs the integration job.
- [ ] Send the result to the session kanbanviewkit-fb when done.