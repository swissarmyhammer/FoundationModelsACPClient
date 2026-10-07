---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4b4tb1q37yknhkwqph2d001
  text: |-
    Research and implementation notes:
    - `ConnectionModel` had one `logger` (the init default). `connect(over:logger:...)` can take a different logger for each connection, and `ModelClient` logs through that connection logger. The doc of `logger` says that it is used only when `connect` gets no logger. To obey that contract, I added `connectionLogger` (internal getter, set in `init` and in `connect`). The warnings for removed MCP servers go through `connectionLogger`. This is the "logger" of step 3 of the card.
    - `advertisesTransport(of:)` is internal in `ConnectionModel+Initialize.swift`. `advertisedMCPServers(in:)` uses it as its filter. The logging helper `advertisedMCPServersWarningOfEachRemoved(in:)` in `ConnectionModel+Sessions.swift` also uses it.
    - The warning has the name and the wire transport. A server of an unknown transport (`MCPServer.unknown(type, payload)`) gets its name from a string `name` member of the payload, if there is one. If not, the text says "an MCP server with no name".
    - Existing MCP tests (`newSessionHoldsItsMCPServersAsNotReported`, `resumeReplacesTheMCPServersOfAnOpenSession`, `aFailedResumeKeepsTheMCPServers`, `newSessionAppliesAStatusUpdateThatFollowsTheResponse`, `aRequestWithNoMCPServersGivesAnEmptyList`) connected with the baseline capabilities, which have no `session.mcp`. After this change, they would send no server. They now connect with the new fixture `eachMCPTransportCapabilities`. Their assertions did not change.
    - `SessionFactoryFixtures.connect` has a new `logger:` parameter, so a test can capture the warnings.
    - RED: all 4 new tests failed because the agent got each server (12 issues). GREEN: 39/39 in ConnectionModelSessionTests.
  timestamp: 2026-10-07T12:18:38.775350+00:00
- actor: claude-code
  id: 01m4b4tds0zkr2k39c5z44dgmv
  text: |-
    ### implement — changed
    - evidence: 6 files changed: Sources/FoundationModelsACPClient/Model/ConnectionModel.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Initialize.swift, Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift, Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift, Tests/FoundationModelsACPClientTests/Model/ConnectedModel.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift. `swift test --filter ConnectionModelSessionTests`: 39 passed, 0 failed. `swift test`: 515 tests in 45 suites passed, 0 failed. The only warning is the accepted SwiftPM MLX "missing creator for mutated node" warning (^zws9qzt).
    - next: /review
  timestamp: 2026-10-07T12:18:41.568062+00:00
- actor: claude-code
  id: 01m4b56y2sanwhgedcpmr630az
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (bbb4f78); 2 findings (2 confirmed, 0 refuted) — Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift:46, Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift:125 (duplication/duplication)
    - next: implement the 2026-10-07 07:20 Review Findings. Remove the duplicated copy-and-filter of the request in newSession(_:) and resumeInTurn(_:) with one shared helper, then review again.
  timestamp: 2026-10-07T12:25:31.481873+00:00
- actor: claude-code
  id: 01m4b579f4f31ew5j4mc4nrtf7
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files
    - test: green — swift test, 515 passed, 0 failed, 0 skipped
    - commit: bbb4f78
    - review: findings — Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift:46, Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift:125
  timestamp: 2026-10-07T12:25:43.140520+00:00
- actor: claude-code
  id: 01m4b5e50fwspab83kabstk9ex
  text: |-
    Review findings of 2026-10-07 07:20 (both duplication/duplication, one cause):
    - Added the internal protocol `MCPServerListRequest` (`var mcpServers: [MCPServer]? { get set }`) in ConnectionModel+Sessions.swift. `NewSessionRequest` and `ResumeSessionRequest` conform with empty extensions (the generated structs already have a `public var mcpServers`).
    - Added the internal generic helper `ConnectionModel.removingUnadvertisedMCPServers(from:)`. It holds the copy-and-filter that was in `newSession(_:)` and in `resumeInTurn(_:)`. The two methods now call it. The file has no other copy of the pattern (`replay` reads `request.mcpServers` but does not copy or filter).
    - The helper is internal, not private, so the test target reaches it through `@testable import`.
    - TDD: new test `removingUnadvertisedMCPServersChangesOnlyTheServersOfEachRequestKind`. RED: compile error, no member `removingUnadvertisedMCPServers`. GREEN: 1 passed.
  timestamp: 2026-10-07T12:29:27.951688+00:00
- actor: claude-code
  id: 01m4b5e6xg5hms801aq2jdbkkj
  text: |-
    ### implement — changed
    - evidence: 2 files changed: Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelSessionTests.swift. `swift test`: 516 tests in 45 suites passed, 0 failed. The only warning is the accepted SwiftPM MLX "missing creator for mutated node" warning (^zws9qzt). Both 2026-10-07 07:20 findings are checked.
    - next: /review
  timestamp: 2026-10-07T12:29:29.904464+00:00
depends_on:
- 01M49F8ES2T6QBK5BAPK8SKZ98
position_column: doing
position_ordinal: '80'
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

- [x] With `session.mcp.http` and `session.mcp.stdio` advertised, each server goes to the agent.
- [x] With only `session.mcp.stdio` advertised, the agent gets no HTTP server, and `SessionModel.mcpServers` has no item for it.
- [x] With no `session.mcp`, the agent gets an empty list or no list, and the session opens.
- [x] A removed server gives one warning in the log.
- [x] `resumeSession(_:)` applies the same rule.

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

- [x] Record `mcpServers` in `ScriptedStubAgent` and write the four failing tests.
- [x] Add `advertisedMCPServers(in:)`.
- [x] Filter the request in `newSession(_:)` and `resumeInTurn(_:)`, and log each removed server.

## Review Findings (2026-10-07 07:20)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift:46` `duplication/duplication` — Lines 46-47 are duplicated verbatim at lines 125-126. Both blocks create a mutable copy of the request and filter its MCP servers with identical logic, risking divergence if one copy is modified independently. Extract a generic helper function or protocol extension to filter MCP servers that both newSession and resumeInTurn can call. For example, define a protocol that both NewSessionRequest and ResumeSessionRequest conform to, with a method that filters the mcpServers field.
- [x] `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift:125` `duplication/duplication` — Lines 125-126 are duplicated verbatim at lines 46-47. Both blocks create a mutable copy of the request and filter its MCP servers with identical logic, risking divergence if one copy is modified independently. Extract a generic helper function or protocol extension to filter MCP servers that both newSession and resumeInTurn can call. For example, define a protocol that both NewSessionRequest and ResumeSessionRequest conform to, with a method that filters the mcpServers field.
