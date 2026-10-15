---
assignees:
- claude-code
depends_on:
- 01M4Z939HBTNVJ8F4X94C99WW9
position_column: done
position_ordinal: f580
title: 'Gap G2: the stub agent sends its prompt script before the prompt response (old turn order)'
---
#mail-step-6 Found in T0.

`ScriptedStubAgent.prompt(_:)` sends the permission request, the elicitation and the whole `script` BEFORE it returns the prompt response. This is the old turn order. ACPAgent 293be4b answers `session/prompt` at once; the echo, `running`, the chunks and `idle` come after the response.

The client tests thus prove the prompt link and the transcript only in the old order.

Change (T2): add a stub option that sends the script after the response (`afterRespondingToCurrentRequest`), and a fixed-order test: response, echo of the `messageId`, `running`, chunks, `idle` with `end_turn`. The local user message links by the `messageId` of the response, the echo adds no second entry, and the transcript shows the answer.

No test is deleted.