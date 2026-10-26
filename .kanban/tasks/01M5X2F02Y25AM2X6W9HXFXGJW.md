---
assignees:
- claude-code
position_column: doing
position_ordinal: '80'
title: Give a named GraphQLEndpoint over the _sah/graphql tunnel
---
Request from KanbanViewKit (^n7mvj7h).

Add a public type that conforms to `FoundationModelsExtras.GraphQLEndpoint` and sends each call through the `_sah/graphql/*` tunnel of a connection.

- API: `SAHGraphQLClient.endpoint(named:sessionId:) async throws -> SAHGraphQLEndpoint`. Name, version, scope and schema come from `endpoints()`.
- `[String: Map]` variables go to the tunnel as JSON. The result is JSON text with sorted keys and no escaped slashes, the same as `KanbanGraph`.
- A `.sessionFolder` endpoint is bound to one session id. A `.server` endpoint needs none.
- The client ignores `viewer`. The agent fills the viewer from the connection.
- An unknown name throws a typed error.
- A `_sah/graphql/error` of a subscription gives one last response with the errors, and the stream then ends, as the protocol tells.

Tests, with an in-process agent that serves `KanbanGraph`:
- [x] (a) one query through the tunnel endpoint and through `KanbanGraph` gives equal text.
- [x] (b) one mutation through the tunnel endpoint gives one subscription event.
- [x] (c) an unknown name throws.
- [x] (d) an `external` viewer gets `UNREACHABLE_BOARD` for a different board (unit test only).
- [x] `swift test` passes (692 tests), and the integration tests pass (9 tests in GraphQLTunnelTests).

Note: the real agent gives `userDevice` trust to a stdio or in-memory connection. Only an HTTP connection with no device token is `external`. Thus the integration test cannot check (d) over stdio.