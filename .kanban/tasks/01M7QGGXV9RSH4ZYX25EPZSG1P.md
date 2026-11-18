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

`Package.resolved` is not tracked, so CI resolves fresh and gets dad60cc. CI is red from run 43953310812 (2026-11-16) and each run after it.

Found during ^3m450tv. Local work-around: the local `Package.resolved` holds FoundationModelsKanban at d07d5b0.

## Decision (2026-11-18): the fix is in FoundationModelsKanban

The Kanban `Package.swift` puts `.interoperabilityMode(.Cxx)` on each target, also on the public library target. The reason in its comment is only the test target, which links FoundationModelsMultitool → FoundationModelsRouter → llama.cpp. The library target needs no C++: `libgit2` is a C API, and the `FoundationModelsExtras` library product has no C++ interoperability. Thus the correct fix is in Kanban: set the mode on the test target only.

Brief to the Kanban owner: /Users/wballard/github/swissarmyhammer/.briefs/kanban-cxx-interop.md (sent through testudoapp-9a).

Do NOT add C++ interoperability to our test target. It is the fallback only if the Kanban owner refuses the fix; then record the reason here.

## Change in this package

None, if Kanban takes the fix. When the Kanban sha comes:

1. Remove the local `Package.resolved` (and `IntegrationTests/Package.resolved`) and resolve fresh.
2. Run `swift build --build-tests` and `swift test`. Build the nested `IntegrationTests` package.
3. Push a commit (the kanban state is enough) and see the CI run go green, both the unit job and the integration job.

## Acceptance

- [ ] FoundationModelsKanban main has C++ interoperability only on its test target (the sha is in a comment here).
- [ ] With no `Package.resolved`, `swift build --build-tests` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] CI on `main` is green: the unit job and the integration job.