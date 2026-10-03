---
assignees:
- claude-code
depends_on:
- 01M3YR1XW7S2KVG2ABV6NP8VDV
- 01M3YRBGEKBG5X2Z9MFCFH2WSW
- 01M3YREME90QMSRYG4V8XPJBW9
position_column: todo
position_ordinal: '8980'
title: Move acp-client AgentSession, DecliningClient and ProbeCommand to ConnectionModel
---
## What
The CLI is the first real consumer of the new models. This task moves the connection part; the turn loop moves in the TurnRunner task.

- [ ] `Sources/AcpClientCore/AgentSession.swift`: hold a `ConnectionModel(coalescingCadence: .zero, clock: <the injected clock>)`; use `connect(over:logger:client:)`, `initialize`, and `newSession` (the models now open the spans; remove the `ClientRequestSpan.run` wraps here). Read `state` where it read `connectionState`. Give the `SessionModel` to the TurnRunner.
- [ ] `AgentSession.closeSession`: keep the current output. Call `connection.close(session)`. Map `ConnectionModelError.unsupported` (the agent has no close capability) and `RequestError.methodNotFound` to the SAME event line that `methodNotFound` writes now; do not throw.
- [ ] `Sources/AcpClientCore/DecliningClient.swift`: the wrap closure is `@Sendable @MainActor (any Client) -> any Client` (task jge1qvf). `DecliningClient` takes the inner `any Client`, declines permissions and elicitations as now, and forwards `sessionUpdate` and `elicitationComplete` to the inner client.
- [ ] `Sources/AcpClientCore/ProbeCommand.swift`: read `availableCommands` as an Optional (nil = not reported) in place of `hasReportedAvailableCommands`. Update the doc comments in `FrameTeeTransport.swift` that name `SwiftUIACPClient`.

## Acceptance Criteria
- [ ] No file in `Sources/AcpClientCore` except `TurnRunner.swift` names `SwiftUIACPClient` or `ACPSessionState`.
- [ ] `acp-client probe` and `doctor` give the same stdout, stderr and exit codes as before (the integration tests below are the proof).
- [ ] Close against an agent without close support writes the same event line as before.

## Tests
- [ ] Update `Tests/FoundationModelsACPClientTests/AgentSessionTests.swift`, `DecliningClientTests.swift`, `ProbeReportTests.swift`; add a test for each close mapping.
- [ ] Update `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/TransportTestSupport.swift`, `CLITestSupportTests.swift`, `AgentProcessTests.swift`.
- [ ] These integration suites pass unchanged in their assertions: `ProbeCommandTests`, `DoctorCommandTests`, `RunCommandExitTests`.
- [ ] `swift test` passes and `swift test --package-path IntegrationTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.