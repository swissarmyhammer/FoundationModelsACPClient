---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'Elicitation phase 6, task 30: one FIFO list of the pending permissions and elicitations of a session'
---
Source: elicitation-plan.md task 30 and section 4 (one deck, one FIFO order by arrival time).

Today a session model has two separate lists: `pendingPermissions` and `pendingElicitations`. The request deck needs one list in arrival order. The connection model holds the request-scoped elicitations.

Steps: design to the step owner first (it must say what happens to the current lists), then code with fixed-order tests, one full run, commit, and push after acceptance.

#elicitation-phase-6