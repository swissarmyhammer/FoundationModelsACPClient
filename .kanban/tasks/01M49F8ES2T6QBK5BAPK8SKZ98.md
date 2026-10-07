---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Model: SessionModel holds the MCP servers of the session, each with its status'
---
## What

AgentViewKit binds its views to the observable state of this client. It must show the MCP servers of a session. Now the client sends `NewSessionRequest.mcpServers` and `ResumeSessionRequest.mcpServers` (type `[MCPServer]?`, from FoundationModelsACP `Generated/Unions.generated.swift:692`) and keeps no copy.

This task makes the types and the list of the servers that the client sent. Task ^d8d4384 applies the status reports of the agent, and adds items for the servers of the agent configuration. The types here must agree with the message shape in task ^d8d4384 (agent tasks 3ywmbw4 and cbqsngc on the FoundationModelsACPAgent board).

1. Add `Sources/FoundationModelsACPClient/Model/MCPServerItem.swift`:
   - `@MainActor @Observable public final class MCPServerItem: Identifiable`. `id` is `name`, because the name is the key of a server in a session.
   - `public let name: String`.
   - `public let transport: MCPServerTransport`, a `public enum` with the cases `.stdio` and `.http` (wire values `"stdio"` and `"http"`).
   - `public let origin: MCPServerOrigin`, a `public enum` with the cases `.client` (the client sent the server) and `.config` (the agent configuration gave the server). Each item of this task is `.client`.
   - `public let server: MCPServer?`: the configuration that the client sent, or `nil` for a `.config` item.
   - `public internal(set) var status: MCPServerStatus`. `MCPServerStatus` is a `public enum` with these cases: `.notReported`, `.connecting`, `.connected`, `.failed(reason: String?)`, `.closed`. The wire values are in task ^d8d4384. Each new item starts at `.notReported`.
   - A `MCPServer.unknown` value does not become an item.
2. In `Sources/FoundationModelsACPClient/Model/SessionModel.swift`, add `public internal(set) var mcpServers: [MCPServerItem] = []` and an internal `func setMCPServers(_ servers: [MCPServer])` that makes one `.client` item for each HTTP or stdio server, in request order, each with status `.notReported`.
3. In `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift`:
   - `newSession(_:)`: call `session.setMCPServers(request.mcpServers ?? [])` directly after `makeSubscribedSessionModel(sessionId:over:)`, in the same synchronous main-actor step, before the stream task of the model can fold an update. Thus a status update that the agent sends after the response always finds the list.
   - `replay(_:into:over:)` (used by `resumeSession(_:)`): set the list from `request.mcpServers` BEFORE the request goes out, beside `session.beginReplay(replayFrom:)`. The agent sends its status updates after the response, so a list set after the response could erase them. On a failed request, put back the list that the open model had before. A resume of an open model replaces the list, and each item starts again at `.notReported`.

## Acceptance Criteria

- [ ] `SessionModel.mcpServers` holds one `.client` `MCPServerItem` for each HTTP or stdio server of the `session/new` request, in request order.
- [ ] Each item has the name, the transport, the origin `.client`, the sent `MCPServer`, and the status `.notReported`.
- [ ] `resumeSession(_:)` sets the list from the resume request before the request goes out, also for a session that is open.
- [ ] A `session/resume` that fails puts back the earlier list of an open model.
- [ ] A request with `mcpServers == nil` gives an empty list.
- [ ] `swift build` gives no new warning.

## Tests

- Add tests to `Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift` (use `SessionFactoryFixtures.connect()` and `InMemoryTransport` through `ScriptedStubAgent`, no sleeps):
  - `newSessionHoldsItsMCPServersAsNotReported`
  - `resumeReplacesTheMCPServersOfAnOpenSession`
  - `aFailedResumeKeepsTheMCPServers`
  - `aRequestWithNoMCPServersGivesAnEmptyList`
- Command: `swift test --filter ConnectionModelSessionTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [ ] Write the four failing tests.
- [ ] Add `MCPServerItem`, `MCPServerTransport`, `MCPServerOrigin` and `MCPServerStatus`.
- [ ] Add `SessionModel.mcpServers` and `setMCPServers(_:)`.
- [ ] Set the list in `newSession(_:)` and before the resume request, and put it back on a failed resume.
