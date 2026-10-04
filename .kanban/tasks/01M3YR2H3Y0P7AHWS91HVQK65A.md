---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m43ej412vfg977jp7p4fprdn
  text: |-
    Research done. Findings:
    - ConnectionModel.connect(over:logger:bufferLimits:client:) returns the ClientSideConnection; wrap gets the ModelClient router as `any Client`. initialize/newSession/close all go through ClientRequestSpan.send, so AgentSession drops its ClientRequestSpan.run wraps for these three.
    - ConnectionModel.close(_:) throws ConnectionModelError.unsupported(method: "session/close") when the agent advertises no `capabilities.session` (canCloseSessions false), and then sends nothing. The integration stubs advertise `{"session":{}}`, so they still get session/close. ScriptedStubAgent defaults to AgentCapabilities() (no session), so unit tests that need a sent close must give `capabilities: AgentCapabilities(session: ...)`.
    - newSession subscribes the model first. A second raw subscription would lose the kept updates, so TurnRunner gets the SessionModel and reads `updateTap()`, taken before the prompt goes out. Prompt and cancel still go over `session.connection` with ClientRequestSpan.run: that move stays for ^dennhyk.
    - SessionModel.availableCommands is Optional (nil = not reported). newSession seeds it from a non-empty response list.
    - The IntegrationTests binary locator finds acp-client beside the test bundle (products dir), so `--scratch-path` for the integration package needs no locator change.
    - IntegrationTests/Support/TransportTestSupport.swift says its helpers match the unit copy word for word. The unit copy still serves SwiftUIACPClient tests (removed in ^2sqtjpw), so only the integration copy moves to the models here; the header comment must say so.
  timestamp: 2026-10-04T12:34:59.746032+00:00
- actor: claude-code
  id: 01m43f3tf6ayjsbyjb5y9sbrac
  text: |-
    Implementation landed.
    - AgentSession holds `model: ConnectionModel(coalescingCadence: .zero, clock:)`; `initialize`/`openSession` go through `model.initialize`/`model.newSession` (no `ClientRequestSpan.run` wraps here now). `openSession()` returns the `SessionModel`. `closeSession(_ session: SessionModel)` calls `model.close(session)`; `RequestError.methodNotFound` and `ConnectionModelError.unsupported` both write "session/close was not answered: <error>"; every other error writes "session/close failed: <error>"; nothing throws.
    - DecliningClient takes `inner: any Client` (the ModelClient router) and forwards `sessionUpdate`/`elicitationComplete`.
    - ProbeCommand reads `SessionModel.availableCommands` (Optional); `ProbeSlashCommands.reported(_:)` now maps nil to `waitEndedFirst`.
    - TurnRunner: only the change the card asks — it gets the SessionModel and reads its update tap (a second raw subscription would miss the kept updates). Prompt/cancel through the model stay for ^dennhyk (comment left there).
    - Doc comments: FrameTeeTransport, TurnRunner, ProbeReport no longer name the container.
    - Discovery: unit stubs (ScriptedStubAgent) default to no `capabilities.session`, so the close tests and TracedSessionHarness now give `AgentCapabilities(session: SessionCapabilities())`. The refused-close telemetry tests now run initialize + session/new before the close, because the model closes a SessionModel, not an id.
    - The IntegrationTests binary locator reads the products dir beside the test bundle, so `--scratch-path` worked with no locator change.
    - The integration TransportTestSupport helpers waitForIdle/initializedConnection/promptTurnLandsReply now drive the models; the unit copy keeps the container forms (header comment says so) until ^2sqtjpw removes SwiftUIACPClient.

    ### implement — changed
    - evidence: `swift build --build-tests` (scratch build): no warning except the accepted MLX "missing creator for mutated node"; `swift test`: 527 tests in 43 suites passed; `swift test --package-path IntegrationTests` (scratch integration-build): 103 tests in 14 suites passed (ProbeCommandTests, DoctorCommandTests, RunCommandExitTests unchanged in their assertions).
    - files: Sources/AcpClientCore/{AgentSession,DecliningClient,ProbeCommand,ProbeReport,TurnRunner,FrameTeeTransport}.swift; Tests/FoundationModelsACPClientTests/{AgentSessionTests,DecliningClientTests,ProbeReportTests,TurnRunnerTests}.swift; Tests/FoundationModelsACPClientTests/Telemetry/{TracedSessionHarness,ClientRequestSpanTests,ClientRequestMetricsTests,ContentSafetyTests}.swift; IntegrationTests/.../{AgentProcessTests,CLITestSupportTests,Support/TransportTestSupport}.swift
    - next: /review
  timestamp: 2026-10-04T12:44:39.782226+00:00
- actor: claude-code
  id: 01m43f929bf41zdb1fsg3kjngh
  text: |-
    ### test - green
    - evidence: swift build --build-tests (root, after touching all changed Swift files): complete, 0 warnings except the accepted SwiftPM "missing creator for mutated node". swift test (root): 527 tests in 43 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests: 103 tests in 14 suites passed, 0 failed, 0 skipped. IntegrationTests build also had 0 warnings except the accepted one. Both used the scratchpad --scratch-path.
    - next: review
  timestamp: 2026-10-04T12:47:31.627907+00:00
- actor: claude-code
  id: 01m43f9jcp80e97t8ynekcr741
  text: |-
    ### commit — changed
    - evidence: One local commit "refactor(cli): move AgentSession, DecliningClient and ProbeCommand to ConnectionModel". The sha is in the git log. No push was done.
    - note: acp-client sends no session/close when the agent has no close capability.
    - next: review
  timestamp: 2026-10-04T12:47:48.118121+00:00
depends_on:
- 01M3YR1XW7S2KVG2ABV6NP8VDV
- 01M3YRBGEKBG5X2Z9MFCFH2WSW
- 01M3YREME90QMSRYG4V8XPJBW9
position_column: doing
position_ordinal: '80'
title: Move acp-client AgentSession, DecliningClient and ProbeCommand to ConnectionModel
---
## What
The CLI is the first real consumer of the new models. This task moves the connection part; the turn loop moves in the TurnRunner task.

- [x] `Sources/AcpClientCore/AgentSession.swift`: hold a `ConnectionModel(coalescingCadence: .zero, clock: <the injected clock>)`; use `connect(over:logger:client:)`, `initialize`, and `newSession` (the models now open the spans; remove the `ClientRequestSpan.run` wraps here). Read `state` where it read `connectionState`. Give the `SessionModel` to the TurnRunner.
- [x] `AgentSession.closeSession`: keep the current output. Call `connection.close(session)`. Map `ConnectionModelError.unsupported` (the agent has no close capability) and `RequestError.methodNotFound` to the SAME event line that `methodNotFound` writes now; do not throw.
- [x] `Sources/AcpClientCore/DecliningClient.swift`: the wrap closure is `@Sendable @MainActor (any Client) -> any Client` (task jge1qvf). `DecliningClient` takes the inner `any Client`, declines permissions and elicitations as now, and forwards `sessionUpdate` and `elicitationComplete` to the inner client.
- [x] `Sources/AcpClientCore/ProbeCommand.swift`: read `availableCommands` as an Optional (nil = not reported) in place of `hasReportedAvailableCommands`. Update the doc comments in `FrameTeeTransport.swift` that name `SwiftUIACPClient`.

## Acceptance Criteria
- [x] No file in `Sources/AcpClientCore` except `TurnRunner.swift` names `SwiftUIACPClient` or `ACPSessionState`.
- [x] `acp-client probe` and `doctor` give the same stdout, stderr and exit codes as before (the integration tests below are the proof).
- [x] Close against an agent without close support writes the same event line as before.

## Tests
- [x] Update `Tests/FoundationModelsACPClientTests/AgentSessionTests.swift`, `DecliningClientTests.swift`, `ProbeReportTests.swift`; add a test for each close mapping.
- [x] Update `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/TransportTestSupport.swift`, `CLITestSupportTests.swift`, `AgentProcessTests.swift`.
- [x] These integration suites pass unchanged in their assertions: `ProbeCommandTests`, `DoctorCommandTests`, `RunCommandExitTests`.
- [x] `swift test` passes and `swift test --package-path IntegrationTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.