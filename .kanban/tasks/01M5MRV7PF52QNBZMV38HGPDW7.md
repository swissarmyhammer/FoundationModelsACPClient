---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Move InProcessAgent from AgentViewKit into FoundationModelsACPClient
---
## Source

Request from the KanbanViewKit session (../KanbanViewKit/plan.md §3.3, §7.3, §8). Also for the Testudo Mac app (D54).

## Why

`InProcessAgent.makeConnection(serving:)` is in AgentViewKit (../AgentViewKit/Sources/AgentViewKit/ACP/InProcessAgent.swift). It uses only FoundationModelsACP and `ConnectionModel`, so its home is this library. KanbanViewKit needs it for its end-to-end tests and its demo app, and a kit cannot link another kit.

## What

- Add `Sources/FoundationModelsACPClient/InProcessAgent.swift` (or a good folder) with `public enum InProcessAgent` and `public static func makeConnection(serving makeAgent: @Sendable (AgentSideConnection) -> any Agent) async -> ConnectionModel`. Keep the name and the signature.
- Keep the behavior: `InMemoryTransport.pair()`, an `AgentSideConnection` on the agent end, a task that waits for `agentConnection.closed` and then closes the two ends, and `ConnectionModel.connect(over:)` on the client end.
- Port the doc comment. Remove the AgentViewKit words: "plan.md §3.9", "The kit does not import an agent package", and the link to `InitializeRequest.makeAgentViewKitRequest(info:terminalAuthRunner:)` (that symbol is in AgentViewKit). Use a plain `InitializeRequest` in the example.

## Tests

Port ../AgentViewKit/Tests/AgentViewKitTests/ACP/InProcessAgentTests.swift. That test uses AgentViewKit helpers (`InMemoryDemoACPAgent`, `AgentConnectionBox`, `ObservationWait`, `agentMessageText`). Use the test helpers of this package in their place (for example Tests/FoundationModelsACPClientTests/Model/ConnectedModel.swift and RawBurstAgent.swift), or add a small test agent. Keep the four cases:

- [ ] The returned model is connected.
- [ ] A prompt round trip puts the reply of the agent in the transcript.
- [ ] The state of the model becomes disconnected after the agent closes.
- [ ] A disconnect of the model closes the agent side with `endOfInput`.

## Note for AgentViewKit (do not edit AgentViewKit here)

After this card is done, AgentViewKit must delete its copy (Sources/AgentViewKit/ACP/InProcessAgent.swift and Tests/AgentViewKitTests/ACP/InProcessAgentTests.swift) and use the type of FoundationModelsACPClient. No AgentViewKit session runs now. Make a card on the AgentViewKit board, or tell the user, when this card is done. This library keeps no backward compatibility (ARCHITECTURE.md), so the two copies must not stay.

## Acceptance

- [ ] Public `InProcessAgent` in FoundationModelsACPClient, same name and signature.
- [ ] Ported tests pass.
- [ ] README mentions the helper.
- [ ] Send the result to the session kanbanviewkit-fb when done. #kanbanviewkit