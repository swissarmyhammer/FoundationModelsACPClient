---
assignees:
- claude-code
position_column: done
position_ordinal: ffb180
title: A background tool call stays busy until its real end
---
The agent keeps a background tool call `in_progress` with `_meta.sah.backgroundRun.completionToken` until the real end. Then it sends completed, failed, or cancelled on the same toolCallId.

Add these client members:
1. `ToolCallEntry.backgroundRun`: the completion token from `_meta.sah.backgroundRun.completionToken`, or nil.
2. `SessionModel.background`: the `background` list of `agentState`.
3. `ToolCallEntry.isStale`: true for a call that is not final when the session closed (the connection ended), or when the session is idle and the call is not in the `background` list.

Test: a scripted stream of (1) tool_call_update in_progress with the marker, (2) state_update idle with background:[toolCall], (3) tool_call_update completed. After step 2 the status is in progress, endedAt is nil, and isStale is false. With no background entry in step 2, isStale is true. After step 3 the status is completed and endedAt is set. backgroundRun is the token.

Requested by testudoapp-75 for OpenTestudo. Tell testudoapp-75 and agentviewkit-0b the commit. #bug