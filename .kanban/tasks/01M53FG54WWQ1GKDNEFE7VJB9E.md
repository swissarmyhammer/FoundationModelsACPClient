---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'Group D (d): the PendingRequestQueue comment says "when the turn gets cancelled"'
---
PendingRequestQueue ~15-18 uses turn wording, and the statement is false (see SessionModel+Pending ~73-75). Correct the comment.