---
assignees:
- claude-code
position_column: todo
position_ordinal: '9880'
title: Fold AgentProcessTests onto the shared temporary-file writer, and remove the scripts it leaves
---
## What

`IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentProcessTests.swift`
holds a private `writeScript(_:)`. It is a near-copy of the writer that
`Support/StubAgents.swift` now shares:
`Support/TemporaryFiles.swift` gives
`writeTemporaryFile(_:prefix:suffix:)`, and `writeAgentScript(_:)` and
`writeStandardInputFile(_:)` both call it.

`AgentProcessTests.swift` stood outside the change that made the shared writer,
so the duplication rule kept the fix on the changed side. This card is the
other half.

Two things to do:

- Delete the private `writeScript(_:)` from `AgentProcessTests.swift` and call
  `writeAgentScript(_:)` in its place, or call
  `writeTemporaryFile(_:prefix:suffix:)` directly when the `acp-agent-` prefix
  is worth keeping.
- Remove each script the tests write. Measured after a full run, the temporary
  directory holds many `acp-agent-*.sh` files and several
  `acp-agent-child-*.pid` files, because no test removes what it wrote. The
  stub-agent tests already do this with `defer { removeAgentScript(script) }`;
  follow that shape.

## Acceptance Criteria

- [ ] `AgentProcessTests.swift` holds no temporary-file writer of its own.
- [ ] After `swift test --package-path IntegrationTests`, the temporary
      directory holds no `acp-agent-*` file.
- [ ] Every assertion in the integration suite still passes.

## Tests

- [ ] Run `swift test --package-path IntegrationTests`, then list the
      temporary directory and confirm it holds nothing the run wrote.
