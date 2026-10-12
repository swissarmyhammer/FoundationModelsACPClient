---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Remove the SwiftPM "Conflicting identity for foundationmodelsacpclient" warning of the IntegrationTests package
---
## Problem
`swift test --package-path IntegrationTests` writes this warning two times:
"'foundationmodelsacpagent': Conflicting identity for foundationmodelsacpclient ... This will be escalated to an error in future versions of SwiftPM."

FoundationModelsACPAgent depends on FoundationModelsACPClient by URL. The nested `IntegrationTests` package depends on the root by `path: ".."` (Shape 2 of `../workflows/docs/swift-ci.md`). SwiftPM uses the path dependency (there is no checkout of the URL), so the test is correct today. SwiftPM exempts only a root package from this check (`allowedToOverride = root.manifests.values.contains(node.manifest)` in `ModulesGraph+Loading.swift`), and the nested package is the root.

## Why ^nnd1wxj did not remove it
- The in-process agent needs the agent package in the graph. That gives the warning.
- The `acp-agent` executable has no greedy decoding option, and ^nnd1wxj requires greedy decoding. Also, a build of the executable in this graph gives the same warning.
- A helper package outside the graph (an executable that serves `RoutedACPAgent` with a greedy router, built by `swift build` inside the test) removes the warning, but it adds a second package and a build in the test.

## Options
1. Upstream (FoundationModelsACPAgent): add a greedy option to `acp-agent`, or move the targets that link the client out of the package that holds the library.
2. The helper package described above.
3. Accept the warning, as ^zws9qzt accepts the MLX warning.

## Acceptance criteria
- [ ] `swift test --package-path IntegrationTests` writes no "Conflicting identity" warning, and the test still uses the local library.