---
assignees:
- claude-code
depends_on:
- 01M49F8ES2T6QBK5BAPK8SKZ98
position_column: todo
position_ordinal: '8180'
title: 'Model: send only the MCP servers whose transport the agent advertises'
---
## What

ACP v2 initialization (https://agentclientprotocol.com/protocol/v2/initialization#param-mcp) lets the client send an MCP server only when the agent advertises its transport in `AgentCapabilities.session?.mcp` (`MCPCapabilities.http` and `MCPCapabilities.stdio`, FoundationModelsACP `Generated/Models5.generated.swift:137`). Now `ConnectionModel.newSession(_:)` and `resumeSession(_:)` send `request.mcpServers` with no check.

1. In `Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift`, add an internal `func advertisedMCPServers(in servers: [MCPServer]?) -> [MCPServer]?`:
   - Keep an `.http` server only when `agentCapabilities?.session?.mcp?.http != nil`.
   - Keep a `.stdio` server only when `agentCapabilities?.session?.mcp?.stdio != nil`.
   - Remove each `.unknown` server.
   - `nil` in gives `nil` out.
2. In `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift`, in `newSession(_:)` and `resumeInTurn(_:)`, copy the request, set `mcpServers` to the filtered list, and send the copy. `SessionModel.mcpServers` (task ^k8skz98) gets the filtered list, so the kit shows only the servers that went to the agent.
3. Log one warning through `logger` for each removed server, with its name and its transport. Do not throw: the session opens with the other servers.
4. In `Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift`, record `params.mcpServers` of `newSession` and `resumeSession` beside `workingDirectories`, so a test reads what went on the wire.

## Acceptance Criteria

- [ ] With `session.mcp.http` and `session.mcp.stdio` advertised, each server goes to the agent.
- [ ] With only `session.mcp.stdio` advertised, the agent gets no HTTP server, and `SessionModel.mcpServers` has no item for it.
- [ ] With no `session.mcp`, the agent gets an empty list or no list, and the session opens.
- [ ] A removed server gives one warning in the log.
- [ ] `resumeSession(_:)` applies the same rule.

## Tests

- Add tests to `Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift`, with `SessionFactoryFixtures.connect(capabilities:)` and the new record on `ScriptedStubAgent`:
  - `newSessionSendsEachServerWhoseTransportTheAgentAdvertises`
  - `newSessionRemovesAnHTTPServerThatTheAgentDoesNotAdvertise`
  - `newSessionWithNoMCPCapabilitySendsNoServer`
  - `resumeSessionRemovesAServerThatTheAgentDoesNotAdvertise`
- Command: `swift test --filter ConnectionModelSessionTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [ ] Record `mcpServers` in `ScriptedStubAgent` and write the four failing tests.
- [ ] Add `advertisedMCPServers(in:)`.
- [ ] Filter the request in `newSession(_:)` and `resumeInTurn(_:)`, and log each removed server.
