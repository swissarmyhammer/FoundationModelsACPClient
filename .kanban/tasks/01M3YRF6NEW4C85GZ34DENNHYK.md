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
depends_on:
- 01M3YR2H3Y0P7AHWS91HVQK65A
position_column: todo
position_ordinal: '9080'
title: 'Move acp-client TurnRunner to SessionModel: stream from the update tap, prompt and cancel through the model'
---
## What
Move `Sources/AcpClientCore/TurnRunner.swift` from `connection.updates(for:)` and direct requests to the `SessionModel`. Keep the behavior of `cli-plan.md` §8 exactly.

- [ ] Read updates from `session.updateTap()` (task 65x5kjr): each raw update in arrival order, not delayed by coalescing. Keep the current `for await update in updates` loop and its handling: each `agent_message_chunk` is written to stdout at once; the spinner gets tool names from `toolCallUpdate.title` (`.value(title)`) as now.
- [ ] Send the prompt with `session.prompt(_:meta:)` and the cancel with `session.cancel(meta:)`, and give the recorded prompt trace parent as `meta` to the cancel, so the `session/cancel` span keeps the prompt span as its parent.
- [ ] End of turn: an idle `state_update` on the tap ends the turn as now. The tap stream ends without an idle update (the connection closed, so the model closed) → throw `TurnEndedWithoutIdleError` as now.

## Acceptance Criteria
- [ ] The bytes on stdout are identical to the current output for the same scripted agent, and each chunk is written when it arrives.
- [ ] The spinner receives each tool title.
- [ ] An agent that stops in the middle of a turn gives `TurnEndedWithoutIdleError` and the same exit code as before.
- [ ] Ctrl-C sends `session/cancel` with the prompt span as its parent.

## Tests
- [ ] Update `Tests/FoundationModelsACPClientTests/TurnRunnerTests.swift`: chunk-at-arrival test, tool-title test, end-without-idle test, cancel-parent test.
- [ ] Update the `TracedSessionHarness` users and `Tests/FoundationModelsACPClientTests/Telemetry/ContentSafetyTests.swift` and `ClientRequestSpanTests.swift`.
- [ ] These integration suites pass unchanged in their assertions: `RunCommandExitTests`, `StreamRulesTests`, `InterruptTests`.
- [ ] `swift test` passes and `swift test --package-path IntegrationTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.