---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4b2fqh8xpchs1b9sqkdqgae
  text: |-
    Picked up. Research:
    - `MCPServer` (FoundationModelsACP Unions.generated.swift) has `.http(MCPServerHTTP)`, `.stdio(MCPServerStdio)`, `.unknown(String, JSONValue)`. Both known payloads have `name: String`.
    - `NewSessionRequest` and `ResumeSessionRequest` have `mcpServers: [MCPServer]? = nil` in their init.
    - `ConnectionModel+Sessions.swift`: `newSession(_:)` calls `makeSubscribedSessionModel` with no suspension before `seed`, so `setMCPServers` goes there in the same main-actor step. `replay(_:into:over:)` calls `beginReplay` before the request; the list goes beside it, and the catch of the request puts back the earlier list.
    - `mcpServers` is `public internal(set)`, so the connection model extension can put back the earlier array directly (same objects, same status).
    - No ARCHITECTURE.md exists. Validators for .swift: code-hygiene, code-security, completeness, duplication, reuse, swift, test-integrity.
  timestamp: 2026-10-07T11:37:53.960677+00:00
- actor: claude-code
  id: 01m4b2pbkbmvsjmse7yzhs781w
  text: |-
    Implementation landed (TDD).
    - RED: the four new tests failed with an empty `mcpServers` list (types and the empty property only, no wiring).
    - GREEN: `setMCPServers(_:)` maps each server through `MCPServerItem.init?(clientServer:)`, which gives `nil` for `MCPServer.unknown`. `newSession(_:)` sets the list directly after `makeSubscribedSessionModel`. `replay(_:into:over:)` keeps the earlier array, sets the new list beside `beginReplay`, and puts the earlier array (same objects, same status) back in the catch of the request.
    - `resumeReplacesTheMCPServersOfAnOpenSession` holds the resume answer with `resumeSessionGate` and checks the list while the agent holds the answer, so it proves the list is set before the response.
    - `MCPServerItem.name` and `id` are `nonisolated`, as `ErrorEntry.id` is, so the `Identifiable` conformance compiles on a main-actor class.
    - No wire values for `MCPServerStatus` are in this task; task ^d8d4384 adds them.
  timestamp: 2026-10-07T11:41:31.115040+00:00
- actor: claude-code
  id: 01m4b2pdqrqyv07hxyke7bn2q0
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPClient/Model/MCPServerItem.swift (new), Sources/FoundationModelsACPClient/Model/SessionModel.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift. `swift test --filter ConnectionModelSessionTests`: 34 passed (4 new). `swift build`: no new warning (only the accepted MLX "missing creator" warning). `swift test`: 496 tests in 44 suites passed, 0 failed, 0 skipped.
    - next: /review. The task stays in doing.
  timestamp: 2026-10-07T11:41:33.304723+00:00
- actor: claude-code
  id: 01m4b318pcstqn40ek7ad9dm4t
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (5448511), 4 Swift files reviewed, 7 validator runs, 0 findings, 0 confirmed, 0 refuted. The .kanban files were excluded by .reviewignore.
    - next: none. The task moved to done.
  timestamp: 2026-10-07T11:47:28.588207+00:00
- actor: claude-code
  id: 01m4b31hdtxear31yk5bwr0j8t
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files
    - test: green — swift test, 496 passed, 0 failed, 0 skipped
    - commit: 5448511
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-10-07T11:47:37.530175+00:00
position_column: done
position_ordinal: d380
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

- [x] `SessionModel.mcpServers` holds one `.client` `MCPServerItem` for each HTTP or stdio server of the `session/new` request, in request order.
- [x] Each item has the name, the transport, the origin `.client`, the sent `MCPServer`, and the status `.notReported`.
- [x] `resumeSession(_:)` sets the list from the resume request before the request goes out, also for a session that is open.
- [x] A `session/resume` that fails puts back the earlier list of an open model.
- [x] A request with `mcpServers == nil` gives an empty list.
- [x] `swift build` gives no new warning.

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

- [x] Write the four failing tests.
- [x] Add `MCPServerItem`, `MCPServerTransport`, `MCPServerOrigin` and `MCPServerStatus`.
- [x] Add `SessionModel.mcpServers` and `setMCPServers(_:)`.
- [x] Set the list in `newSession(_:)` and before the resume request, and put it back on a failed resume.
