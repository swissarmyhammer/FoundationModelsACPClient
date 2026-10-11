---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4nxzzsb3af6t6kpr8hfcgas
  text: |-
    Research done.
    - `TracedCall.run` (FoundationModelsExtras) opens the span through `tracer.withSpan`, which reads `ServiceContext.current` as the parent. Thus `ServiceContext.withValue(.topLevel)` around it gives a root span.
    - `ClientRequestSpan.ParentContext(extractingFrom:tracer:)` gives `nil` when `TraceContextMeta.extract` refuses the value. `TraceContextMeta` checks the W3C format (lower-case hex, no all-zero ids), so an invalid `traceparent` gives `nil` and the new span is a root.
    - `FinishedInMemorySpan` has `traceID`, `spanID` and `parentSpanID`, so the tests can check the parent directly.
    - The three agent wire names are in `MethodTable.generated.swift` of FoundationModelsACP: `session/request_permission`, `elicitation/create`, `elicitation/complete`. No source of this package writes them as literals today.
    - Duplication rule: the "enter" metadata and the two span attributes of `ClientRequestSpan.run` are the same for the new span. Plan: make `ClientRequestSpan.enterMetadata` internal and move the two attribute writes into one internal helper that both spans call, so that no copy exists. This touches `ClientRequestSpan.swift` a little more than the method names; the reason is the duplication rule.
  timestamp: 2026-10-11T16:51:02.571749+00:00
- actor: claude-code
  id: 01m4nyaaavy2xg7w5y7qwx37eq
  text: |-
    Implementation done (TDD).
    - RED: the new tests and the vocabulary tests did not compile, because `AgentRequestSpan`, `SpanName.agentRequest`, `AttributeKey.outcome`/`routed`, `OutcomeValue` and the three `Method` names did not exist.
    - GREEN: `swift test --filter "AgentRequestSpan|ACPClientTelemetryVocabulary"` passed 16 tests in 2 suites (the root-span test runs 3 cases: no `_meta`, a `_meta` without `traceparent`, and an invalid `traceparent`).
    - Full suite: `swift test` passed 443 tests in 35 suites. The only warning is the SwiftPM "missing creator for mutated node" warning from the MLX bundle of FoundationModelsExtras. The user accepted it on task 01M3Z8M7YKRR5TQ5NRPZWS9QZT; this change does not cause it.
    - Duplication rule: `ClientRequestSpan.enterMetadata` is now internal (it was private), and the two attribute writes moved into the new internal `ClientRequestSpan.setRequestAttributes`. Both spans call these two functions, so no copy exists. This is the only change to `ClientRequestSpan.swift` other than the three method names and the doc line of `Method`.
    - `AgentRequestSpan` is internal and has no production caller yet; task ^3n0fydz adds the caller in ModelClient. The tests call it, and periphery runs with `--build-tests`, so a dead-code marker is not necessary.
  timestamp: 2026-10-11T16:56:41.051548+00:00
- actor: claude-code
  id: 01m4nyb1awvm9vagsms0vxhk8k
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPClient/Telemetry/AgentRequestSpan.swift (new), Sources/FoundationModelsACPClient/Telemetry/ACPClientTelemetry.swift, Sources/FoundationModelsACPClient/Telemetry/ClientRequestSpan.swift, Tests/FoundationModelsACPClientTests/Telemetry/AgentRequestSpanTests.swift (new), Tests/FoundationModelsACPClientTests/Telemetry/ACPClientTelemetryVocabularyTests.swift. `swift test --filter "AgentRequestSpan|ACPClientTelemetryVocabulary"`: 16 tests passed. `swift test`: 443 tests in 35 suites passed. The one warning is the MLX "missing creator for mutated node" warning that the user accepted on 01M3Z8M7YKRR5TQ5NRPZWS9QZT.
    - next: /review
  timestamp: 2026-10-11T16:57:04.604226+00:00
- actor: claude-code
  id: 01m4nyd334t8p5h3277cagnxk5
  text: |-
    ### test — green
    - evidence: swift test — 443 tests in 35 suites passed, 0 failed, 0 skipped. One warning only: the known "missing creator for mutated node" warning from the MLX bundle (task 01M3Z8M7YKRR5TQ5NRPZWS9QZT).
    - next: review
  timestamp: 2026-10-11T16:58:11.940675+00:00
position_column: doing
position_ordinal: '80'
title: 'Add AgentRequestSpan: a server span for each request that the agent sends'
---
## What

Add one helper that opens a `.server` span for a request or notification that the agent sends to the client. The span starts in the trace context that the agent put in the `_meta` of the message. Today, trace context goes out only (`ClientRequestSpan`); no code reads it on the way in.

Spec rule (https://agentclientprotocol.com/protocol/v2/extensibility): "The following root-level keys in `_meta` SHOULD be reserved for W3C trace context ... `traceparent`, `tracestate`, `baggage`." FoundationModelsACP has no tracing code, so this package must make the span.

Files:
- New: `Sources/FoundationModelsACPClient/Telemetry/AgentRequestSpan.swift`
- Modify: `Sources/FoundationModelsACPClient/Telemetry/ACPClientTelemetry.swift`
- Modify: `Sources/FoundationModelsACPClient/Telemetry/ClientRequestSpan.swift` (the agent method names only)

Approach:
- `enum AgentRequestSpan` (internal) with:
  `nonisolated(nonsending) static func run<Output>(method: String, sessionId: SessionId?, meta: JSONValue?, tracer: (any Tracer)? = nil, logger: Logger? = nil, _ body: nonisolated(nonsending) (any Span) async throws -> Output) async throws -> Output`.
  `TracedCall.run` of FoundationModelsExtras is `async throws`, so this function throws too. Model it on `ClientRequestSpan.run` (`ClientRequestSpan.swift:168`). Use `TracedCall.run` with `ofKind: .server`.
- Parent: when `meta` holds a valid `traceparent`, use `ClientRequestSpan.ParentContext(extractingFrom: meta, tracer:)` (`TracedClientMessage.swift:78`). When it holds no valid `traceparent`, start a NEW ROOT trace with `ServiceContext.topLevel`, and not `ParentContext.current`. Reason: the inbound handler task inherits the `ServiceContext` of the read task, which inherits the context of the code that called `ConnectionModel.connect` (`FoundationModelsACP/.../Connection.swift:546` and `:954`). With `.current`, each agent request would become a child of an old, unrelated host span.
- Attributes: `rpc.method` and `session.id` (existing keys). The body gets the span, so a caller can set the outcome attributes.
- Add to `ACPClientTelemetry`. Each new member is `public`, because `ACPClientTelemetryVocabularyTests.swift` imports the module without `@testable`:
  - `SpanName.agentRequest = prefix + "agent.request"`
  - `AttributeKey.outcome = "acp.response.outcome"`
  - `AttributeKey.routed = "acp.request.routed"` (Bool)
  - `enum OutcomeValue` with `selected`, `cancelled`, `accept`, `decline`, `cancel`, `matched`, `unmatched` and `other`. `other` is the value for an outcome or an action that this list does not name. Rule 4: never write the raw string of the agent.
- Add the agent method names to `ClientRequestSpan.Method` (`ClientRequestSpan.swift:77`), where the package keeps its ACP method names: `requestPermission = "session/request_permission"`, `createElicitation = "elicitation/create"` and `completeElicitation = "elicitation/complete"`. These are the wire names in `MethodTable.generated.swift` of FoundationModelsACP.
- Rule 4: no attribute holds a title, a description, an option name, a message, a URL or form content.
- The helper records no metrics. This task adds spans only.

## Acceptance Criteria
- [x] `AgentRequestSpan.run` opens one span with name `FoundationModelsACPClient.agent.request` and kind `.server`.
- [x] When `meta` holds a valid `traceparent`, the span has the same trace id as that value, and its parent span id is the parent id of that value.
- [x] When `meta` holds no `traceparent` or an invalid one, the span is a root span with a new trace id, also when the call runs inside another span. The call does not fail.
- [x] The span holds `rpc.method`, and `session.id` only when a session id is given.
- [x] An error that `body` throws goes back to the caller unchanged.
- [x] Each new span name and attribute key is in `ACPClientTelemetry.swift` only. No other source file has it as a string literal.

## Tests
- [x] New `Tests/FoundationModelsACPClientTests/Telemetry/AgentRequestSpanTests.swift`: use the in-memory tracer of `TelemetryTestSupport` (as `ClientRequestSpanTests.swift` does). Test the span name and kind, the parent from a valid `traceparent`, a root span for a missing value and for an invalid value (run the call inside an outer span, and check that the new span is not its child), the attributes with and without a session id, and an error from `body`.
- [x] Update `Tests/FoundationModelsACPClientTests/Telemetry/ACPClientTelemetryVocabularyTests.swift` to cover the new names, including the prefix rule.
- [x] Run `swift test --filter "AgentRequestSpan|ACPClientTelemetryVocabulary"`. All tests pass.
- [x] Run `swift test`. All tests pass and the build has no warnings.

## Workflow
- Use `/tdd`: write the failing tests first, then write the code that makes them pass. #telemetry