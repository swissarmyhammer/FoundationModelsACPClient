---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4brc0g670nhrcs88fw14a3y
  text: |-
    Research done.
    - `MCPServerStatusUpdate.decode(_:)` requires a string `transport` in one guard. `MCPServerItem.transport` is a `let`, and two initializers set it: `init?(clientServer:)` (always a known transport) and `init(statusUpdate:)` (copies the update).
    - `SessionModel.applyMCPServerStatus(_:)` changes only `status` of an item that exists. Thus it never writes the transport of an existing item. When the decode accepts an update with no transport, the known transport stays with no more change.
    - Uses of the two `transport` properties: `MCPServerItem.init(statusUpdate:)`; `SessionModelMCPServerStatusTests.aConfigServerUpdateAddsAnItem`; `MCPServerRecord` in `ConnectionModelSessionTests` (copies `item.transport`). The acp-client executable target, `AcpClientCore` and `IntegrationTests` do not use them.
    - Two existing tests list `transport` as a required member: `aMissingRequiredMemberChangesNothing` and `anUnknownOrWrongValueOfARequiredMemberChangesNothing`. The first must drop `transport`, because a missing transport is now valid. The `"sse"` case of the second moves to the new test `anUpdateWithAnUnknownTransportValueIsStillIgnored`.
  timestamp: 2026-10-07T18:00:20.742597+00:00
- actor: claude-code
  id: 01m4brn2rpxrpb37enxn56k2a5
  text: |-
    Implementation done.
    - RED: `swift test --filter SessionModelMCPServerStatusTests` failed with 4 issues. `anUpdateWithNoTransportAddsAServerWithNoTransport` and `anUpdateWithNoTransportKeepsTheKnownTransport` failed because the decode ignored the update. `anUpdateWithAnUnknownTransportValueIsStillIgnored` passed at RED by design: it is a guard on a rule that does not change. It has three cases: `"sse"`, `true`, and `null` (present but not a string).
    - GREEN: `decode(_:)` reads `transport` after the required members. A missing member gives `nil`. A present member that `knownTransport(of:)` cannot read makes the decode ignore the update. `MCPServerStatusUpdate.transport` and `MCPServerItem.transport` are now `MCPServerTransport?` (public API change on `MCPServerItem`).
    - Keep a known transport: `SessionModel.applyMCPServerStatus(_:)` already changes only `status` of an existing item, so no code change was necessary there. The doc comment now says this, and the new test proves it.
    - Test changes from the new rule: `aMissingRequiredMemberChangesNothing` no longer lists `transport`. The `("transport", "sse")` case moved from `anUnknownOrWrongValueOfARequiredMemberChangesNothing` to the new named test. `MCPServerRecord.transport` in `ConnectionModelSessionTests` is now optional.
    - Doc comments also corrected: `SessionModel.mcpServers`, `MCPServerItem.server`, and `MCPServerItem.init(statusUpdate:)` said that only a config server gets an item from an update. Now an update with no transport can also add a `client` item.
    - No use in `AcpClientCore`, the `acp-client` executable, `IntegrationTests`, or Markdown docs.
  timestamp: 2026-10-07T18:05:17.974453+00:00
- actor: claude-code
  id: 01m4brn5p9qcp4xkw7vzc02r6z
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPClient/Model/MCPServerStatusUpdate.swift, Sources/FoundationModelsACPClient/Model/MCPServerItem.swift, Sources/FoundationModelsACPClient/Model/SessionModel.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelMCPServerStatusTests.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift. `swift test --filter SessionModelMCPServerStatusTests`: 17 tests pass. `swift build`: complete. `swift test`: 572 tests in 49 suites pass. `swift build --package-path IntegrationTests --build-tests`: complete. The only warning is the accepted MLX "missing creator for mutated node".
    - next: /review
  timestamp: 2026-10-07T18:05:20.969459+00:00
- actor: claude-code
  id: 01m4brrqyjchhbvpyxzr4wp7y5
  text: |-
    ### test - green
    - evidence: swift build - complete, 0 errors, 0 warnings in package code. swift test - 572 tests in 49 suites passed, 0 failed, 0 skipped. swift build --package-path IntegrationTests --build-tests - complete, 0 errors, 0 warnings in package code.
    - note: the only warning is "missing creator for mutated node" from the MLX bundle. The task accepts it. No warning came from .build/checkouts.
    - next: review. I made no code change.
  timestamp: 2026-10-07T18:07:17.970087+00:00
position_column: doing
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

- [x] An update with no `transport` member, `origin` `client`, `status` `failed` and `reason` "The transport is not known." adds an item to `SessionModel.mcpServers` with `transport == nil`, status failed, and that reason.
- [x] An update with no `transport` for a server that already has an item with `.stdio` keeps `.stdio` and applies the new status.
- [x] An update with a `transport` value that is not known (for example `"sse"`) is still ignored.
- [x] Each existing test passes. `swift build`, `swift test`, and `swift build --package-path IntegrationTests` pass, with no new warning.

## Tests

- In the existing test file for `MCPServerStatusUpdate` and `SessionModel.mcpServers` (under `Tests/FoundationModelsACPClientTests/Model/`):
  - `anUpdateWithNoTransportAddsAServerWithNoTransport`
  - `anUpdateWithNoTransportKeepsTheKnownTransport`
  - `anUpdateWithAnUnknownTransportValueIsStillIgnored`
- Command: `swift test --filter MCPServer`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [x] Write the three failing tests.
- [x] Make `transport` optional on `MCPServerStatusUpdate` and `MCPServerItem`, and keep a known transport.
- [x] Update the doc comments.
