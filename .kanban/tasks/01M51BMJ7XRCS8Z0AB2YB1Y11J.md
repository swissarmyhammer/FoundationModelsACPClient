---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Elicitation phase 3: fold the _mail_delivery_paused session update into SessionModel as an observable pause payload'
---
Source: request of the step owner. Start only when the step owner gives the ACPAgent head.

ACPAgent sends a new extension session update `_mail_delivery_paused` when its Router pauses mail delivery. The session then holds run results and starts no answer until the next caller message. The payload is `{limit, heldCount, heldMail: [{tool, op, completionToken}], message}`. The update is in the session history, so a load replays it.

Work:
- Decode the update, as `_mcp_server_status` is decoded. It must not go to the merge engine, and it adds no transcript entry.
- Keep the last payload on SessionModel as one observable value (the payload, not a busy state).
- Clear the value when this client sends the next prompt.
- Keep the value through a replay: a replayed update sets it again, and a transcript reset does not clear it before the replay gives it.
- Tests in fixed order: decode, set, clear on prompt, replay, and an update that is not valid changes nothing.

Steps: design to the step owner first, then code, one full run, IntegrationTests build, commit, push, and a report of the head and CI.

#elicitation-phase-3