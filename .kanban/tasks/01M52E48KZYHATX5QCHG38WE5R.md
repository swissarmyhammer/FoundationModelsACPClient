---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m52g1vfhb9kn990sp2gxm4hy
  text: |-
    ### test — green
    - PendingElicitationWhoAsksTests: 5 tests (1 raw wire test with and without the keys, and 4 decode tests). The full run passes (628 tests in 51 suites).
  timestamp: 2026-10-16T13:57:31.249253+00:00
position_column: done
position_ordinal: ff8b80
title: 'Who asks: PendingElicitation.agentPath and source from the _meta of elicitation/create'
---
For AgentViewKit task 39 (accepted ACPAgent design). `elicitation/create` can have `_meta` {"agentPath": [String], "source": String}, each one only when it is not empty. The root agent adds no name.

## Done (not committed)
- `PendingElicitation.agentPath: [String]` (an empty list when the value is absent or is not an array of strings).
- `PendingElicitation.source: String?` (nil when the value is absent, is not a string, or is empty).
- Tests: PendingElicitationWhoAsksTests (raw wire test with and without the keys; decode tests for wrong types and for an empty source).

## Next
One full run and one push together with ^s39vtvg and the cancel reason.