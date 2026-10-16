---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: 'Group D (c): two arrival number spaces can mix in one PendingRequestQueue'
---
A nil arrival takes a number from the process-wide PendingArrivalCounter, but a wire number comes from a counter of each connection that starts at 0. If one queue gets both, the order is wrong (this contradicts PendingRequest ~38-43). Fix: use one number space. Start with a test that fails before the fix.