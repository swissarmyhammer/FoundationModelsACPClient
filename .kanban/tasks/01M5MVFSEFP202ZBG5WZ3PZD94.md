---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5n4tt6q7wwtagvg73313kf0
  text: 'Research: the two private copies of `collect` are identical (only the doc text differs: "a completion" and "a normal finish"). SAHGraphQLClientTests.swift has 2 call sites, SAHGraphQLClientConnectionTests.swift has 6. No other helper in the unit target reads a whole stream into an array. Shared test helpers of the target live at the root of Tests/FoundationModelsACPClientTests (for example ThreadSafeBuffer.swift, ObservationWait.swift) as types or extensions. Plan: one internal generic extension `AsyncThrowingStream where Failure == any Error { func collect() async -> (elements: [Element], error: (any Error)?) }` in a new file Tests/FoundationModelsACPClientTests/AsyncThrowingStreamCollection.swift. The call sites change from `collect(stream)` to `stream.collect()`. The var accumulator stays: the helper must keep the elements that came before a thrown error, so `map` or `reduce` cannot replace it.'
  timestamp: 2026-10-23T19:47:00.439875+00:00
- actor: claude-code
  id: 01m5n4y1jm5xqvbxez26vzmbrb
  text: 'Implementation landed. New file Tests/FoundationModelsACPClientTests/AsyncThrowingStreamCollection.swift holds one internal `extension AsyncThrowingStream where Failure == any Error { func collect() async -> (elements: [Element], error: (any Error)?) }`. The two private `collect` functions are gone. All 8 call sites now call `stream.collect()` (2 in SAHGraphQLClientTests.swift, 6 in SAHGraphQLClientConnectionTests.swift). The doc comment in IntegrationTests/.../GraphQLTunnelTests.swift now names `AsyncThrowingStream.collect()` in the new file. The new file names the integration copy too, so each copy points to the other. RED: `swift build --build-tests` failed with "value of type ''AsyncThrowingStream<JSONValue, any Error>'' has no member ''collect''". GREEN: `swift test --filter SAHGraphQLClient` passed 22 tests in 2 suites. Full `swift test`: 684 tests in 56 suites passed, and the only warning was the allowed MLX "missing creator for mutated node" warning. Tool note: the `files` edit op with `replace_all: true` replaced only one site for each call, so each call site needed its own edit.'
  timestamp: 2026-10-23T19:48:46.292279+00:00
- actor: claude-code
  id: 01m5n4y43x2hybqyxgd68g7wmf
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsACPClientTests/AsyncThrowingStreamCollection.swift (new), Tests/FoundationModelsACPClientTests/GraphQL/SAHGraphQLClientTests.swift, Tests/FoundationModelsACPClientTests/GraphQL/SAHGraphQLClientConnectionTests.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/GraphQLTunnelTests.swift (doc comment only); swift test: 684 tests in 56 suites passed, 0 failures, only the allowed MLX warning
    - next: /review
  timestamp: 2026-10-23T19:48:48.893117+00:00
position_column: doing
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

- [x] One `collect` helper in the unit test target, and both GraphQL test files call it.
- [x] The doc comment in GraphQLTunnelTests.swift names the correct place.
- [x] `swift test` passes.