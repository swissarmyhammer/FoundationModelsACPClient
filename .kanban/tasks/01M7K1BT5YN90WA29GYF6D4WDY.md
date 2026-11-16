---
assignees:
- claude-code
position_column: done
position_ordinal: ffb280
title: The client never logs or keeps the answer to a sensitive elicitation
---
ACPAgent 2846d34 marks an elicitation that asks for a secret with `"sensitive": true` in the `_meta` of `elicitation/create`. Make sure that FoundationModelsACPClient never logs or keeps the `content` of the accept response for such a request:
- no wire or frame trace, and no OSLog line, with the params or result of the response
- no kept copy in the session model or in a history
- no debug dump

If a trace logs frames, redact the `content` of each elicitation response.

Test: a scripted wire with a secret marker in the accept content. Then search the OSLog of the process and a dump of the session model for the marker.

Requested by testudoapp-75. Send it the commit, or tell it that no change was necessary. #security