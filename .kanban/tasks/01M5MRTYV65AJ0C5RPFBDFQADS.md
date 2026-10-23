---
assignees:
- claude-code
position_column: todo
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

- [ ] Public initializer over an ACP connection.
- [ ] execute, subscribe, unsubscribe and endpoints use the `_sah/graphql/*` wire.
- [ ] complete finishes the stream normally; error and a closed connection throw. The doc comment of `subscribe` states this rule.
- [ ] Unit tests and integration tests pass. CI runs the integration job.
- [ ] Send the result to the session kanbanviewkit-fb when done.