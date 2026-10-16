---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'Group D (b): a resume does not clear awaitingURLCompletions'
---
beginReplay in SessionModel+Stream clears the notices and the withdrawn records, but not awaitingURLCompletions. An agent that tears the session down at session/resume and sends no elicitation/complete leaves a URL wait forever. Fix: clear it, with a reason, at a resume. Start with a test that fails before the fix.