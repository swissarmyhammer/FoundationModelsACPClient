---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6s7rs9kdv7y03jr08rsyv0r
  text: |-
    ### finish — skipped
    - evidence: /finish (scoped-batch, no filter) on 2026-11-06 found this card as the only ready todo card. It was not started.
    - reason: blocked on the root fix in FoundationModelsACP (AgentSideConnection.init reads before setRole). That repository is not on this board, so the board shows the card as READY. swissarmyhammer-75 said: make no code change until that fix is pushed.
    - next: when swissarmyhammer-75 tells us the fix is pushed, remove the "blocked" tag and run /finish ^510qyhn.
  timestamp: 2026-11-06T20:10:59.251582+00:00
position_column: todo
position_ordinal: '80'
title: Check the integration agent servers when the FoundationModelsACP read-before-setRole fix lands
---
BLOCKED on a root fix in FoundationModelsACP: AgentSideConnection.init must not read the transport before setRole. The swissarmyhammer-75 session tells us when that fix is pushed. Make no code change in this repo before then. The design with a second gate (HeldInboundTransport) was refused: it copies the gate of FoundationModelsACPAgent 51332f3 and only works around the root bug.

## Cause

FoundationModelsACP 9fcca1d, Sources/FoundationModelsACP/Connection/AgentSideConnection.swift:
- line 53: `core = await RoleConnectionCore(stream: ...)` starts the read loop.
- line 68: `core.setRole(agent, ...)` sets the agent role later.
A frame that is already in the pipe can be served before line 68, and `initialize` gets methodNotFound. This caused one failure of GraphQLTunnelTests.aKanbanMutationGivesOneSubscriptionEvent on 2026-11-06.

## Findings: both servers have the race

Both servers serve over stdio, so frames can wait in the pipe before the role is set:
- IntegrationTests/LiveAgentServer/Sources/graphql-tunnel-server/GraphQLTunnelServer.swift:52: `composed.serve(over: StdioTransport())`
- IntegrationTests/LiveAgentServer/Sources/live-agent-server/LiveAgentServer.swift:58: `AgentSideConnection(stream: StdioTransport()) { ... }`

## When the root fix lands

- [ ] Move the FoundationModelsACP pin to the fix commit, in IntegrationTests and in IntegrationTests/LiveAgentServer (`swift package update FoundationModelsACP`; Package.resolved is gitignored, so the pin is local).
- [ ] Do not change the two server lines. They must not get a gate of their own.
- [ ] Check that the root fix has a deterministic test in FoundationModelsACP: a frame that is written before `AgentSideConnection.init` is served by the agent of the factory, and gets no methodNotFound. If it has none, tell swissarmyhammer-75.
- [ ] Add one integration check: write `initialize` into the stdin of graphql-tunnel-server before the agent finishes its start-up (write it immediately after the process starts), and expect a valid InitializeResponse. With the old FoundationModelsACP this can fail; note that it is not deterministic in a subprocess, so the deterministic test stays in FoundationModelsACP.
- [ ] Run the root tests and the IntegrationTests one time. Push, and send the commit to swissarmyhammer-75. #bug #blocked