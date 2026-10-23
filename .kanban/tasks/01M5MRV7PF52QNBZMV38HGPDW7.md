---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5ms2bxt3vbe2h9yb6twanan
  text: |-
    Research done.
    - AgentViewKit sets defaultIsolation(MainActor) on its targets, so its InProcessAgent is @MainActor by default. This package has no default isolation, and ConnectionModel is @MainActor. The port marks InProcessAgent @MainActor to keep the same behavior for the callers.
    - The ComposedAgent example of the doc comment is still correct: ComposedAgent.compose(name:workingDirectory:home:), agent(boundTo:), waitForConnectionTeardown() and AgentHome.makeCustom(synced:local:) exist in FoundationModelsACPAgent now.
    - Test helpers for the port: ScriptedStubAgent (agent), ThreadSafeBuffer (keeps the AgentSideConnection that the factory gets), waitUntil(_:orFailWhen:) (no clock, no poll), makeInitializeRequest(), agentChunk(text:message:), idleState(stopReason:).
    - ConnectionModelTests has a fileprivate ConnectionCloseReason.isEndOfInput. The new test needs it too, so the extension moves to TransportTestSupport.swift to prevent a copy.
    - ConnectionModelTests.disconnectEndsAnInProcessAgent already proves the endOfInput close for a hand-made pair; the new tests prove it through the helper.
  timestamp: 2026-10-23T16:21:25.050928+00:00
- actor: claude-code
  id: 01m5ms72v3vzc0eph6ks8kmd4y
  text: |-
    Implementation landed (TDD).
    - RED: `swift test --filter InProcessAgentTests` failed to compile with "cannot find 'InProcessAgent' in scope" and no other error.
    - GREEN: Sources/FoundationModelsACPClient/InProcessAgent.swift. Same name and signature as AgentViewKit. The enum is @MainActor, because AgentViewKit has a MainActor default isolation and ConnectionModel is @MainActor. The doc comment has no "plan.md §3.9", no "The kit does not import an agent package", and no makeAgentViewKitRequest link. The example has a plain InitializeRequest step.
    - Tests: Tests/FoundationModelsACPClientTests/InProcessAgentTests.swift has the four cases. The agent is ScriptedStubAgent. A ThreadSafeBuffer keeps the AgentSideConnection in place of AgentConnectionBox. waitUntil(_:orFailWhen:) replaces ObservationWait. No sleep, clock wait, poll or .timeLimit.
    - ConnectionCloseReason.isEndOfInput moved from a fileprivate extension in ConnectionModelTests.swift to TransportTestSupport.swift, so the two test files share one copy.
    - README.md: the in-process paragraph now names InProcessAgent.makeConnection(serving:), with an example.
    - Still open after review and commit: the acceptance item "Send the result to the session kanbanviewkit-fb when done", and the AgentViewKit follow-up (delete its copy and its test). This step did not edit AgentViewKit and did not make a card on its board; the user gets the note.
  timestamp: 2026-10-23T16:23:59.587410+00:00
- actor: claude-code
  id: 01m5ms75t3ybkv8qpee6wp3t4c
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPClient/InProcessAgent.swift (new), Tests/FoundationModelsACPClientTests/InProcessAgentTests.swift (new), Tests/FoundationModelsACPClientTests/TransportTestSupport.swift, Tests/FoundationModelsACPClientTests/Model/ConnectionModelTests.swift, README.md. `swift build`: Build complete, only the allowed MLX "missing creator for mutated node" warning. `swift test --filter InProcessAgentTests`: 4 tests passed. `swift test`: 670 tests in 55 suites passed, 0 failed, 0 skipped.
    - next: /review. After commit: send the result to kanbanviewkit-fb, and make the AgentViewKit follow-up (delete its InProcessAgent copy and test).
  timestamp: 2026-10-23T16:24:02.627571+00:00
- actor: claude-code
  id: 01m5msftj82tc2yjxyp9qp5rnf
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (6395cca). 0 findings, 0 confirmed, 0 refuted. 7 files attempted, 0 failed. The engine reviewed 4 files. It did not review README.md (no validator matches it) or the 2 .kanban files (.reviewignore).
    - next: The task is in done. One acceptance item stays open, and it is not a review finding: "Send the result to the session kanbanviewkit-fb when done." The AgentViewKit note also stays open: make a card on the AgentViewKit board to delete its copy of InProcessAgent, or tell the user.
  timestamp: 2026-10-23T16:28:46.024126+00:00
- actor: claude-code
  id: 01m5msg2xbfe0az59zngw28s5w
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files
    - test: green — swift test 670 passed; IntegrationTests 1 passed
    - commit: 6395cca
    - review: clean — 0 findings
    - next: push main, send the sha to kanbanviewkit-fb. AgentViewKit must delete its copy (no AgentViewKit session runs now).
  timestamp: 2026-10-23T16:28:54.571390+00:00
position_column: done
position_ordinal: ff9880
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

- [x] The returned model is connected.
- [x] A prompt round trip puts the reply of the agent in the transcript.
- [x] The state of the model becomes disconnected after the agent closes.
- [x] A disconnect of the model closes the agent side with `endOfInput`.

## Note for AgentViewKit (do not edit AgentViewKit here)

After this card is done, AgentViewKit must delete its copy (Sources/AgentViewKit/ACP/InProcessAgent.swift and Tests/AgentViewKitTests/ACP/InProcessAgentTests.swift) and use the type of FoundationModelsACPClient. No AgentViewKit session runs now. Make a card on the AgentViewKit board, or tell the user, when this card is done. This library keeps no backward compatibility (ARCHITECTURE.md), so the two copies must not stay.

## Acceptance

- [x] Public `InProcessAgent` in FoundationModelsACPClient, same name and signature.
- [x] Ported tests pass.
- [x] README mentions the helper.
- [ ] Send the result to the session kanbanviewkit-fb when done. #kanbanviewkit