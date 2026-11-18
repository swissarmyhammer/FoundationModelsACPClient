---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qpyt9bmpfjvdbw905b0qrr
  text: |-
    ### test — green
    - FoundationModelsKanban resolved at 909c903a66b5088024b8af352e7920d07fa7810e (main). The Package.swift of 909c903 sets .interoperabilityMode(.Cxx) only for targets of type .test.
    - FoundationModelsExtras resolved at 951149ce8b2aa4e13025e3dbd72fb5fcc6cde37d (main), in both packages.
    - Note: after the delete of both Package.resolved files, the first `swift package resolve` took the stale cached checkouts (Kanban d07d5b0, Extras b87233e in root and 3d0eced in IntegrationTests). The IntegrationTests build then failed with "cannot find 'SessionSlug' in scope" (SessionModel+Export.swift). `swift package update` in both packages moved all to main. CI resolves fresh, so it gets the new shas.
    - `swift build --build-tests` (root): complete, exit 0.
    - `swift test` (root): 895 tests in 75 suites passed, 0 failed, 0 skipped.
    - `swift build --build-tests --package-path IntegrationTests`: complete, exit 0.
    - Warnings: only the MLX "missing creator for mutated node" warning for mlx-swift_Cmlx.bundle. No C++ interoperability error. No interoperability mode was added to this package.
    - Acceptance items 1 and 2 are checked. Item 3 (CI green on main, unit job and integration job) is open: it needs a push.
    - next: push a commit and check the CI run.
  timestamp: 2026-11-18T16:13:38.475006+00:00
- actor: claude-code
  id: 01m7qw67q3gp568a6hm5xbdphc
  text: 'CI run 44344782311 (7f2c79d, Kanban 909c903): the unit job "Build & test" passed. The C++ interop error is gone. A newer push (cd18647) cancelled the integration job before it ended, after 1h30m. The integration job did not run on a fresh resolve yet: run 44324128382 skipped it because the unit job failed with the old error. Next: watch the CI run of the last D205 push to its end. Both jobs must be green.'
  timestamp: 2026-11-18T17:45:04.483378+00:00
position_column: doing
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

- [x] FoundationModelsKanban main has C++ interoperability only on its test target (the sha is in a comment here).
- [x] With no `Package.resolved`, `swift build --build-tests` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] CI on `main` is green: the unit job and the integration job.