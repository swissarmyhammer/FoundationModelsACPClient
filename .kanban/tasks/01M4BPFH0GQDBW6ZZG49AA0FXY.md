---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Model: decode an _mcp_server_status update that has no transport member'
---
## What

The FoundationModelsACPAgent session (task ^cbqsngc in that repository) reports this: the agent sends a `_mcp_server_status` update with no `transport` member. It does this when a server that the client sent has a transport that the agent does not know. The reason text is then "The transport is not known.". The other members are as designed: `name`, `origin` (`config` or `client`), `status` (`connected` or `failed`), and `reason` for a failed server.

Now `MCPServerStatusUpdate.init?(update:)` (`Sources/FoundationModelsACPClient/Model/MCPServerStatusUpdate.swift:60`) requires `transport`, so it ignores such an update. Thus the host does not see the failed server, and it does not see the reason. The rule "ignore a member that is not known" does not cover a member that is missing.

Change:

1. `MCPServerStatusUpdate.transport` becomes `MCPServerTransport?`. A missing `transport` member gives `nil`. A `transport` member that is present but is not a string, or has a value that this client does not know, still makes the decode ignore the whole update (this rule does not change).
2. `MCPServerItem.transport` (`Sources/FoundationModelsACPClient/Model/MCPServerItem.swift:93`) becomes `MCPServerTransport?`. Its doc comment says that `nil` means "the agent did not tell the transport". This is a public API change.
3. When an update with no transport matches an item that already has a transport, keep the transport of the item. Do not write `nil` over a known value.
4. Update the doc comment of the decode (the member list at line 15 and the rules at line 51): `transport` is optional.

## Acceptance Criteria

- [ ] An update with no `transport` member, `origin` `client`, `status` `failed` and `reason` "The transport is not known." adds an item to `SessionModel.mcpServers` with `transport == nil`, status failed, and that reason.
- [ ] An update with no `transport` for a server that already has an item with `.stdio` keeps `.stdio` and applies the new status.
- [ ] An update with a `transport` value that is not known (for example `"sse"`) is still ignored.
- [ ] Each existing test passes. `swift build`, `swift test`, and `swift build --package-path IntegrationTests` pass, with no new warning.

## Tests

- In the existing test file for `MCPServerStatusUpdate` and `SessionModel.mcpServers` (under `Tests/FoundationModelsACPClientTests/Model/`):
  - `anUpdateWithNoTransportAddsAServerWithNoTransport`
  - `anUpdateWithNoTransportKeepsTheKnownTransport`
  - `anUpdateWithAnUnknownTransportValueIsStillIgnored`
- Command: `swift test --filter MCPServer`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [ ] Write the three failing tests.
- [ ] Make `transport` optional on `MCPServerStatusUpdate` and `MCPServerItem`, and keep a known transport.
- [ ] Update the doc comments.
