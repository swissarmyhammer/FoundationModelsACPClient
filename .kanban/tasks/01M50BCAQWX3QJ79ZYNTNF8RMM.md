---
assignees:
- claude-code
position_column: done
position_ordinal: fd80
title: 'Defect: ConnectionModel.session(for:) is not observed while the session is not open'
---
Found while I worked on ^hfby9sz.

The lookup read only `openSessionPositions`, which is `@ObservationIgnored`, when the session was not open. An observation of the lookup then tracked nothing, so a waiter (a test, or a SwiftUI view) never saw the later register of the session. A resume test waited for ever on this.

Fix: the lookup always reads the observable `openSessions`. The doc says this. The SessionOpenQuestionTests suite covers it: before the fix, the resume test hung after the connect.

#defect