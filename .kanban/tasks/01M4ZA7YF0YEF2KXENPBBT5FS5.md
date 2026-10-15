---
assignees:
- claude-code
depends_on:
- 01M4Z939HBTNVJ8F4X94C99WW9
position_column: todo
position_ordinal: '8680'
title: 'Gap G3: no test for state updates with no prompt open, an idle with no stop reason, and two open prompts'
---
Found in T0. The model code already accepts each case (it stores each `state_update` as is, at any time, and links each local prompt by its own `messageId`). No test proves it in the new ACPAgent order.

Change (T2), fixed-order tests over the connection, with the stub sending after the prompt response:
1. After the prompt ended (idle `end_turn`), the agent sends `running`, a compaction entry (`in_progress`, then `completed`), and `idle` with NO stop reason. `agentState` is idle with no stop reason, the compaction entry is after the answer, and its timing ends at `completed`.
2. Two prompts open at the same time: each response gives its own `messageId`, the two echoes come in the other order, and each local user message links to its own echo with no second entry.
3. `session/cancel` while a prompt is open: the prompt response says `cancelled` at once, and the `idle` with `cancelled` comes later, from a gate. #mail-step-6