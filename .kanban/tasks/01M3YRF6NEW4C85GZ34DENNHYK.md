---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m43dq524s7draqvc75gcemwy
  text: 'Note from ^8xpjbw9 (implement): `SessionModel.cancel(meta:)` now uses a W3C `traceparent` in the given `meta` as the parent of the `session/cancel` span (`ClientRequestSpan.ParentContext(extractingFrom:)` in `ConnectionSessionRequestSender.cancel`). But `SessionModel.prompt(_:meta:)` opens the prompt span inside the sender, so `TurnRunner` can no longer record `ParentContext.current` inside the span closure as it does now. This task must find a way to give the cancel the traceparent of the sent prompt. The ^8xpjbw9 test reads it from the `_meta` that the stub agent received.'
  timestamp: 2026-10-04T12:20:16.068530+00:00
- actor: claude-code
  id: 01m43f3hbdba4m73tehdgxbf7x
  text: 'Note from ^hvqk65a: `AgentSession.openSession()` now gives the `SessionModel` that `ConnectionModel.newSession` opened. That model holds the only subscription that gets the kept updates, so `TurnRunner.run()` already reads `opened.updateTap()` (made before the prompt goes out) and `readTurn(from:)` now takes `AsyncStream<SessionUpdate>`. The end-of-turn handling is unchanged: idle on the tap ends the turn, and a tap that ends (the model closed) gives `TurnEndedWithoutIdleError`. Still open for this card: send the prompt with `session.prompt(_:meta:)` and the cancel with `session.cancel(meta:)` (TurnRunner still calls `session.connection.prompt`/`sessionCancel` inside `ClientRequestSpan.run`), and the TurnRunnerTests listed on this card.'
  timestamp: 2026-10-04T12:44:30.445027+00:00
- actor: claude-code
  id: 01m43fvx7vb39qcnmpbd14m67f
  text: |-
    Research (implement):
    - TurnRunner already reads `opened.updateTap()` (^hvqk65a). Still open: prompt and cancel go over `session.connection` inside `ClientRequestSpan.run`, and a `PromptTraceContext` actor records `ParentContext.current` inside the prompt span.
    - Problem: `SessionModel.prompt` opens the prompt span inside `ConnectionSessionRequestSender.prompt` (through `ClientRequestSpan.send`), so the traced `_meta` exists only inside the sender. TurnRunner cannot see it.
    - Plan: the internal `SessionRequestSender.prompt` gets a second parameter, a `@MainActor` closure that receives the request with its final `_meta` just before it goes out (inside the span). `SessionModel.prompt` uses it to record the W3C trace context of the sent prompt in a new public read-only `SessionModel.promptTraceMeta: JSONValue?` (only the `traceparent`/`tracestate` members, through `TraceContextMeta.extract(from:)?.inject(into: nil)`). TurnRunner sends the prompt with `opened.prompt(_:)` and the cancel with `opened.cancel(meta: opened.promptTraceMeta)`; `ConnectionSessionRequestSender.cancel` already parents the cancel span on that traceparent (^8xpjbw9). The record is set before the request goes out, as the old actor was, so a cancel after the agent got the prompt always sees it. The `PromptTraceContext` actor is deleted.
    - Trace tree stays the same: the prompt span still starts in the context of the prompt child task; the cancel span is still a child of the prompt span.
    - Existing guard: `ClientRequestSpanTests.theCancelCarriesTheTraceOfTheTurn` drives TurnRunner and checks `cancelSpan.parentSpanID == promptSpan.spanID`.
    - Side effect to know: with `SessionModel.prompt`, the transcript now holds the local user message of the prompt, and a refused prompt adds an error entry. No telemetry change.
  timestamp: 2026-10-04T12:57:49.051870+00:00
- actor: claude-code
  id: 01m43gatqc897encn4tr46r9ba
  text: |-
    Implementation landed (TDD).
    - The trace parent of the cancel: the internal `SessionRequestSender.prompt` now takes `willSend: @MainActor @Sendable (PromptRequest) -> Void`. `ConnectionSessionRequestSender` calls it inside the prompt span with the traced request, before the request goes out. `SessionModel.prompt` records only the W3C trace members (`TraceContextMeta.extract(from:)?.inject(into: nil)`) in the new public read-only `SessionModel.promptTraceMeta` (`@ObservationIgnored`, `public internal(set)`). It is reset on each prompt, so a prompt with no trace context leaves `nil`. `FakeSessionRequestSender` calls `willSend` with the request unchanged.
    - TurnRunner: prompt goes out with `opened.prompt(_:)`, the first Ctrl-C sends `opened.cancel(meta: opened.promptTraceMeta)`. The `PromptTraceContext` actor and every direct `session.connection` request are gone from TurnRunner. The trace tree is unchanged: the prompt span still opens in the context of the prompt child task, and the cancel span is a child of the prompt span (checked by test).
    - Behavior note: the prompt now also shows in the session transcript as a sent user message, and a refused prompt adds an error entry. Neither reaches stdout, stderr or telemetry.
    - Tests: new `SessionModelPromptTests.promptRecordsTheTraceContextOfTheSentRequest` and `promptWithNoTraceContextRecordsNone` (RED: compile error, no `promptTraceMeta`), `ModelRequestSpanTests.aPromptRecordsTheTraceContextThatTheAgentGot`; `TurnRunnerTests`: `thePromptGoesOutThroughTheSessionModel` (RED: no user message in transcript), `eachAnswerChunkReachesTheSinkWhenItArrives`, `theSpinnerReceivesEachToolTitle`, the end-without-idle test is now parameterized over no limit and a limit, and the cancel-parent test moved from `ClientRequestSpanTests.theCancelCarriesTheTraceOfTheTurn` to `TurnRunnerTests.theCancelOfTheTurnIsAChildOfThePromptSpan` (moved, not copied). `TracedSessionHarness` and `ContentSafetyTests` header comments updated.
    - Validator rules: read the Swift-relevant and generic sections of the dumped rule file (the file is 657 KB; the sections for Dart, Go, Python, Rust, TypeScript and the tool-internal measurement tables of idioms-swift / magic-numbers-swift / missing-docs-swift were not read in full).
  timestamp: 2026-10-04T13:05:57.996753+00:00
- actor: claude-code
  id: 01m43gay297k3m5ecrewa8c7jb
  text: |-
    ### implement — changed
    - evidence: 10 files — Sources/AcpClientCore/TurnRunner.swift, Sources/FoundationModelsACPClient/Model/SessionModel.swift, Sources/FoundationModelsACPClient/Model/SessionModel+Prompt.swift, Sources/FoundationModelsACPClient/Model/SessionRequestSender.swift, Sources/FoundationModelsACPClient/Model/ConnectionSessionRequestSender.swift, Tests/FoundationModelsACPClientTests/TurnRunnerTests.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelPromptTests.swift, Tests/FoundationModelsACPClientTests/Model/FakeSessionRequestSender.swift, Tests/FoundationModelsACPClientTests/Telemetry/{ModelRequestSpanTests,ClientRequestSpanTests,TracedSessionHarness,ContentSafetyTests}.swift. `swift build`: exit 0, only the accepted MLX "missing creator" warning. `swift test`: 533 tests in 43 suites passed. `swift test --package-path IntegrationTests`: 103 tests in 14 suites passed (run exits, stream rules, Ctrl-C, --timeout included).
    - next: /review
  timestamp: 2026-10-04T13:06:01.417448+00:00
- actor: claude-code
  id: 01m43gb1np2936kqqgrbf5pqdv
  text: 'Correction to the step record above: the file count is 12, not 10 (5 source files and 7 test files, as the list names).'
  timestamp: 2026-10-04T13:06:05.110512+00:00
- actor: claude-code
  id: 01m43gejd9z2fgt8xfj7th51sh
  text: |-
    ### test — green
    - evidence: swift build --build-tests (root) complete. swift test (root): 533 tests in 43 suites passed. swift test --package-path IntegrationTests: 103 tests in 14 suites passed. 0 failures, 0 skipped. Only warning: accepted SwiftPM "missing creator for mutated node" (mlx-swift).
    - next: none
  timestamp: 2026-10-04T13:08:00.553162+00:00
- actor: claude-code
  id: 01m43gf27k8f8jv8m9zy4jbvcj
  text: |-
    ### commit — changed
    - evidence: local commit "refactor(cli): send the TurnRunner prompt and cancel through SessionModel". The sha is in the step record of the commit agent.
    - next: review. The new public SessionModel.promptTraceMeta holds the trace parent of the last prompt. The cancel uses it.
  timestamp: 2026-10-04T13:08:16.755370+00:00
depends_on:
- 01M3YR2H3Y0P7AHWS91HVQK65A
position_column: doing
position_ordinal: '80'
title: 'Move acp-client TurnRunner to SessionModel: stream from the update tap, prompt and cancel through the model'
---
## What
Move `Sources/AcpClientCore/TurnRunner.swift` from `connection.updates(for:)` and direct requests to the `SessionModel`. Keep the behavior of `cli-plan.md` §8 exactly.

- [x] Read updates from `session.updateTap()` (task 65x5kjr): each raw update in arrival order, not delayed by coalescing. Keep the current `for await update in updates` loop and its handling: each `agent_message_chunk` is written to stdout at once; the spinner gets tool names from `toolCallUpdate.title` (`.value(title)`) as now.
- [x] Send the prompt with `session.prompt(_:meta:)` and the cancel with `session.cancel(meta:)`, and give the recorded prompt trace parent as `meta` to the cancel, so the `session/cancel` span keeps the prompt span as its parent.
- [x] End of turn: an idle `state_update` on the tap ends the turn as now. The tap stream ends without an idle update (the connection closed, so the model closed) → throw `TurnEndedWithoutIdleError` as now.

## Acceptance Criteria
- [x] The bytes on stdout are identical to the current output for the same scripted agent, and each chunk is written when it arrives.
- [x] The spinner receives each tool title.
- [x] An agent that stops in the middle of a turn gives `TurnEndedWithoutIdleError` and the same exit code as before.
- [x] Ctrl-C sends `session/cancel` with the prompt span as its parent.

## Tests
- [x] Update `Tests/FoundationModelsACPClientTests/TurnRunnerTests.swift`: chunk-at-arrival test, tool-title test, end-without-idle test, cancel-parent test.
- [x] Update the `TracedSessionHarness` users and `Tests/FoundationModelsACPClientTests/Telemetry/ContentSafetyTests.swift` and `ClientRequestSpanTests.swift`.
- [x] These integration suites pass unchanged in their assertions: `RunCommandExitTests`, `StreamRulesTests`, `InterruptTests`.
- [x] `swift test` passes and `swift test --package-path IntegrationTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.