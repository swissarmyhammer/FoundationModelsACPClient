---
assignees:
- claude-code
depends_on:
- 01M4NX8Q4WFYJMHPCGWG6RJXDC
position_column: todo
position_ordinal: '8180'
title: Open a server span in ModelClient for each permission request and elicitation of the agent
---
## What

Wrap each handler of `ModelClient` (`Sources/FoundationModelsACPClient/Model/ModelClient.swift`) in `AgentRequestSpan.run`. Then a trace shows how long the agent waited for the user, and the span of the agent joins the span of the client.

Files:
- Modify: `Sources/FoundationModelsACPClient/Model/ModelClient.swift`
- Modify: `Sources/FoundationModelsACPClient/Model/ConnectionModel+Elicitation.swift`: make `completeElicitation(elicitationId:)` (line 104) return `Bool`, as `SessionModel.completeElicitation` does (`SessionModel+Pending.swift:217`). The span needs to know if a holder matched.
- Modify: `Tests/FoundationModelsACPClientTests/Model/ModelClientTests.swift`: line 227 calls `completeElicitation` and must use the new `Bool` result (for example `#expect(!...)`), so that the build has no unused-result warning.
- Modify: `Tests/FoundationModelsACPClientTests/Telemetry/TracedSessionHarness.swift` (see Tests).
- New: `Tests/FoundationModelsACPClientTests/Telemetry/AgentRequestSpanRoutingTests.swift`
- Modify: `Tests/FoundationModelsACPClientTests/Telemetry/ContentSafetyTests.swift`

Each handler:
- `requestPermission(_:)` (line 64): method `ClientRequestSpan.Method.requestPermission`, `sessionId` = `params.sessionId`, `meta` = `params.meta`. Outcome `selected` or `cancelled`, from the `outcome` of the response. `RequestPermissionOutcome.unknown` gives `other`. Spec rule (prompt-lifecycle): the client MUST answer each pending permission request with `cancelled` when it cancels a turn. Thus `cancelled` is a normal outcome. Do not give it the error status.
- `createElicitation(_:)` (line 85): method `ClientRequestSpan.Method.createElicitation`. `sessionId` only for `.session` scope. Outcome from the `action` member of the response: `accept`, `decline` or `cancel`. Each other value, and a response with no `action`, gives `other`. `CreateElicitationResponse` is raw JSON, so never copy the raw string (rule 4).
- `elicitationComplete(_:)` (line 100): method `ClientRequestSpan.Method.completeElicitation`. Outcome `matched` or `unmatched`, from the new `Bool` return.
- When no model takes the request (session not open, request-scoped elicitation with no request in flight, unknown mode), set `acp.request.routed = false`. Otherwise set it to `true`. The `ACPLogger` warnings stay as they are.
- `sessionUpdate(_:)` gets no span. A span for each update makes too many spans.
- Rule 4: no attribute holds the title, the description, the option names, the message, the URL or the form content.

## Acceptance Criteria
- [ ] A permission request that the user answers gives one `.server` span with `rpc.method = session/request_permission`, `session.id`, `acp.request.routed = true` and `acp.response.outcome = selected`.
- [ ] A permission request for a session that is not open gives `routed = false` and outcome `cancelled`.
- [ ] A session-scoped elicitation gives outcome `accept`, `decline` or `cancel`, as the user answered. A request-scoped elicitation has no `session.id`.
- [ ] An unknown permission outcome, and an elicitation `action` that is not `accept`, `decline` or `cancel`, give outcome `other`. The raw string is in no attribute.
- [ ] `elicitation/complete` gives outcome `matched` when a model held the elicitation, and `unmatched` when no model held it.
- [ ] When the `_meta` of the agent message holds a valid `traceparent`, the span is a child of that span context.
- [ ] The span ends after the user answers. Thus its duration includes the wait for the user.

## Tests
- [ ] `TracedSessionHarness.swift`: add an option to use the real router of the model for permission requests, in place of `PermissionDecliningClient` (lines 113-115). The default stays the declining client, so `ClientRequestSpanTests` and `ClientRequestMetricsTests` do not change. Add an elicitation parameter that passes to the `elicitation` member of `ScriptedStubAgent`.
- [ ] New `AgentRequestSpanRoutingTests.swift`: drive the real `ConnectionModel` over `InMemoryTransport.pair()` with `ScriptedStubAgent`, in a `TelemetryCapture`, with the real router. Answer each pending permission through `SessionModel.selectPermission(_:option:)` or `cancelPermission(_:)`, and each elicitation through `acceptElicitation`, `declineElicitation` or `cancelElicitation`. Cover each criterion above. Send a `traceparent` in the `_meta` of the stub request and check the parent. Unit-test the mapping of unknown outcomes and actions to `other`.
- [ ] Update `ContentSafetyTests.swift`: use the real-router option. Select the pending permission through the `SessionModel`. Send one session-scoped form elicitation with a message, and accept it with content. Add the elicitation message and the form content to the forbidden strings. The capture must find no forbidden string.
- [ ] Run `swift test --filter "AgentRequestSpanRouting|ContentSafety|ModelClient|ClientRequestSpan|ClientRequestMetrics"`. All tests pass.
- [ ] Run `swift test`. All tests pass and the build has no warnings.

## Workflow
- Use `/tdd`: write the failing tests first, then write the code that makes them pass. #telemetry