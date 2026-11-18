---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Test target: FoundationModelsKanban main needs C++ interoperability'
---
## Problem

FoundationModelsKanban main (dad60cc, after commit 0bb950c "build the integration package with C++ interoperability") gives a module that was built with C++ interoperability. Our test target imports `FoundationModelsKanban` (for example `Tests/FoundationModelsACPClientTests/GraphQL/SAHGraphQLEndpointTests.swift`). With a fresh resolve, `swift build --build-tests` stops with this error:

`module 'FoundationModelsKanban' was built with C++ interoperability enabled, but current compilation does not enable C++ interoperability`

`Package.resolved` is not tracked, so CI resolves fresh and gets dad60cc. Thus CI can fail on `swift test`.

Found during ^m450tv. Local work-around in that task: the local `Package.resolved` holds FoundationModelsKanban at d07d5b0. The other pins were updated to the current mains, because FoundationModelsExtras main (b87233e, `SessionSlug`) needs the newer mlx-swift-lm.

## Change

Decide how the test target links FoundationModelsKanban: enable C++ interoperability on the test target (`swiftSettings: [.interoperabilityMode(.Cxx)]`), or remove the dependency on the Kanban module. Make the fresh resolve build again.

## Acceptance

- [ ] With no `Package.resolved`, `swift build --build-tests` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.