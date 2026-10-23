---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Fold the two `collect` stream helpers of the unit GraphQL tests into one
---
## What

The unit test target has two copies of the private function `collect`. Each copy reads an `AsyncThrowingStream<JSONValue, any Error>` until it ends, and gives the elements and the error.

- `Tests/FoundationModelsACPClientTests/GraphQL/SAHGraphQLClientTests.swift`
- `Tests/FoundationModelsACPClientTests/GraphQL/SAHGraphQLClientConnectionTests.swift`

Both files are in one test target, so one internal helper can serve the two files. Put the helper on a type (not a top-level function), for example an extension of `AsyncThrowingStream`. Remove the two private copies.

The integration copy in `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/GraphQLTunnelTests.swift` stays. Its doc comment names `SAHGraphQLClientConnectionTests.swift` as the copy that it mirrors. If the helper moves, update that doc comment to name the new place.

Found during the fix of the review finding of ^bdfqads.

## Acceptance

- [ ] One `collect` helper in the unit test target, and both GraphQL test files call it.
- [ ] The doc comment in GraphQLTunnelTests.swift names the correct place.
- [ ] `swift test` passes.