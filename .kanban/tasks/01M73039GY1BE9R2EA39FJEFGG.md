---
assignees:
- claude-code
depends_on:
- 01M73027HMPC6MQ49AQ9QHD8D7
- 01M7301R14HFNZGPCXSBQJT8CS
position_column: todo
position_ordinal: '8480'
title: 'ACPC-4: move the SAH GraphQL tunnel (SAHGraphQLSubscriptions and _meta.sah) onto the extension point'
---
## What
Prove the connection part of ACPC-4 with the GraphQL tunnel (ACPC-6: "the client gets the `_sah/graphql/*` notifications through the extension point"). After this task, `ModelClient` has no GraphQL code.

Make these changes:
- [ ] New `Sources/FoundationModelsACPClient/GraphQL/SAHGraphQLExtension.swift`: a `ClientModelExtension`. Its connection state holds the `SAHGraphQLSubscriptions` table of the connection and the `SAH.InitializeMeta?` of the connection.
  - `registerHandlers` registers `_sah/graphql/next`, `_sah/graphql/complete` and `_sah/graphql/error` (the code of `SAHGraphQLSubscriptions.extensionHandlers`).
  - `didInitialize` reads `_meta.sah` (the code that task 01M7301R14HFNZGPCXSBQJT8CS put in `ConnectionModel+Initialize.swift`).
  - `didClose` calls `closeAll()`.
- [ ] `ConnectionModel` registers this extension as a built-in, as the other built-ins.
- [ ] `Model/ModelClient.swift`: remove `graphQLSubscriptions` and the special case in `extensionHandlers`. Remove `ConnectionModel.graphQLSubscriptions`. `ConnectionModel.graphQLRoute()` (`GraphQL/ConnectionGraphQLBackend.swift`) reads the table from the extension state.
- [ ] `ConnectionModel.sah` and `ConnectionModel.graphQLEndpoints` stay public, and read the extension state.
- [ ] Update the doc comment of `connect(over:logger:bufferLimits:client:)`: a wrapping `Client` must give the `extensionHandlers` of the router, which now serve each registered extension.

## Acceptance Criteria
- [ ] `ModelClient.swift` has no reference to `SAHGraphQLSubscriptions`.
- [ ] Each stream of `SAHGraphQLClient.subscribe` ends with `SAHGraphQLError.connectionClosed` when the connection closes, as today.
- [ ] The public API of `SAHGraphQLClient`, `SAHGraphQLEndpoint`, `ConnectionModel.sah` and `ConnectionModel.graphQLEndpoints` does not change.
- [ ] All existing tests pass with no change of their assertions.

## Tests
- [ ] `Tests/FoundationModelsACPClientTests/GraphQL/SAHGraphQLClientConnectionTests.swift`, `SAHGraphQLEndpointTests.swift` and `Model/ConnectionModelInitializeTests.swift` stay green with no change to the assertions.
- [ ] Add one test to `ClientModelExtensionTests.swift`: a host extension and the SAH extension both serve their notifications on one connection.
- [ ] Run `swift test` → all pass, and `swift test --package-path IntegrationTests` → all pass (the `graphql-tunnel-server` tests).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1