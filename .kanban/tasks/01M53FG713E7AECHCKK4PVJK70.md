---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: 'Test rule T1: each wait in a test also ends on the failure event; fixtures close when the body throws'
---
Known: ObservationWait ~19-21 has no limit; WithdrawnRequestTests ~77, 95, 115, 131, 159 wait only for !withdrawnRequests.isEmpty (add `|| isClosed`); WithdrawnRequestTests ~182-186 stops at .disconnected before the handler task makes its record, so it does not prove "no record after close". Search the whole test target. No .timeLimit, sleep, poll or retry. One full run.