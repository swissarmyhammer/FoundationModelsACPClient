---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50e7sj4zp67r0e08mbp7ds5
  text: |-
    ### implement — changed
    - `ClientRequestSpan.run` and `send` get an additive `link: ParentContext?` parameter. The span gets one `SpanLink` with no attributes.
    - `ConnectionSessionRequestSender.cancel(_:linkingTo:)`: the span starts in the context of the caller (`.current`) and links to the span in `link`. It is never a child of a prompt span.
    - `SessionModel.cancel(meta:)`: the link is the traceparent in `meta`, or else `promptTraceMeta`, or else no link. The signature and the wire do not change.
    - Wording: the "turn" text in `Method.cancelSession`, `ParentContext`, `promptTraceMeta`, the doc of `cancel(meta:)`, `SessionRequestSender` and `OutcomeValue.cancelled` now says "work of the session".
    - Tests: `aCancelWithThePromptTraceparentIsAChildOfThePromptSpan` became `aCancelLinksToThePromptSpanAndIsNotItsChild` (accepted change: the old behavior was the defect). New: `aCancelWithNoMetaLinksToTheLastPromptSpan`, `aCancelBeforeAnyPromptHasNoLink`, `aCancelInsideACallerSpanIsItsChildAndLinksToThePrompt`.
    - Full run: 552 tests in 44 suites pass (549 + 3 new). IntegrationTests builds.
  timestamp: 2026-10-15T18:47:19.876852+00:00
position_column: done
position_ordinal: ff8180
title: 'Elicitation phase 6, task 32: remove the "turn" wording of the cancel telemetry, and stop making session/cancel a child of the prompt span'
---
Source: elicitation-plan.md task 32 (partly done in mail step 6).

What is left:
- The "turn" wording in `ClientRequestSpan.swift` (`Method.cancelSession`, `ParentContext`) and in `SessionModel.promptTraceMeta`.
- `ConnectionSessionRequestSender.cancel` makes the `session/cancel` span a child of the span named by the traceparent in the `_meta`. In practice, that is the `session/prompt` span. A cancel now acts on the work of the whole session, not on one prompt.

Steps:
- Send a short design for the span parent to the step owner, and get acceptance before code.
- Implement it with fixed-order tests.
- Run the full suite one time, then commit.
- Push after the step owner accepts.

#elicitation-phase-6