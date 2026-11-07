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
- actor: claude-code
  id: 01m6v5774pnpdd5905qjqj2afq
  text: |-
    ### finish — skipped
    - evidence: /finish (scoped-batch, no filter) on 2026-11-07. `git fetch` of FoundationModelsACP: origin/main is still 9fcca1d. AgentSideConnection.init still makes RoleConnectionCore (read loop) before core.setRole. The root fix is not pushed.
    - reason: blocked on the root fix in FoundationModelsACP. swissarmyhammer-75 said: make no code change until that fix is pushed.
    - next: when the fix is pushed, remove the "blocked" tag and run /finish ^510qyhn.
  timestamp: 2026-11-07T14:04:55.318066+00:00
- actor: claude-code
  id: 01m6v5s9nsqqpmc8vr7sz6nknf
  text: |-
    ### unblocked — 2026-11-07
    - evidence: `git ls-remote git@github.com:swissarmyhammer/FoundationModelsACP.git refs/heads/main` = b6b265ca6f75badbde7b2614d8f35b04d0c4e034. swissarmyhammer-75 and foundationmodelsacp-32 both said: the root fix is b6b265c (RoleConnectionCore holds the read loop on an InboundGate until setRole). The deterministic tests are Tests/FoundationModelsACPTests/InboundBeforeRoleTests.swift (tests 1 and 2).
    - added by swissarmyhammer-75: update every committed Package.resolved, also in subpackages (root, IntegrationTests, IntegrationTests/LiveAgentServer). Check which ones git tracks. Push, and send the commit to swissarmyhammer-75.
    - next: /finish ^510qyhn.
  timestamp: 2026-11-07T14:14:47.737208+00:00
- actor: claude-code
  id: 01m6v608ab9cmzhzxdev5n3zkw
  text: |-
    ### implement — research and pins
    - `git ls-files` shows no tracked Package.resolved. The root .gitignore has `Package.resolved`. Thus there is no committed Package.resolved to update. The pins are local only.
    - `swift package update FoundationModelsACP` ran in the root, IntegrationTests and IntegrationTests/LiveAgentServer. All three local Package.resolved now pin b6b265ca6f75badbde7b2614d8f35b04d0c4e034 (before: root 364a19a, IntegrationTests 38501cb, LiveAgentServer 9fcca1d).
    - The checkout at b6b265c has Tests/FoundationModelsACPTests/InboundBeforeRoleTests.swift with three tests: readLoopWaitsForTheRoleBeforeItReadsAFrame, closeBeforeTheRoleEndsTheConnectionWithNoResponse, agentServesAnInitializeThatWasWrittenBeforeTheConnection. The deterministic test exists, so no message to swissarmyhammer-75 is necessary for that point.
    - The two server lines (GraphQLTunnelServer.swift, LiveAgentServer.swift) are not changed.
    - New integration check: GraphQLTunnelTests.anInitializeWrittenAtTheProcessStartGetsAnInitializeResponse. It writes a raw `initialize` frame into the stdin of graphql-tunnel-server immediately after the process starts, with no ConnectionModel, and decodes the result as InitializeResponse. `TunnelAgent.startProcess(in:)` is the shared start of the server, so the test does not copy `TunnelAgent.start()`.
    - RED was not seen: the order in a subprocess is not deterministic, as the card says. The single run of the new test passed in 24 s at b6b265c.
  timestamp: 2026-11-07T14:18:35.723666+00:00
- actor: claude-code
  id: 01m6v6498gm40sxt20dbn34wkn
  text: |-
    ### implement — changed
    - evidence: 1 tracked file: IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/GraphQLTunnelTests.swift (new test anInitializeWrittenAtTheProcessStartGetsAnInitializeResponse, helper RawInitialize, TunnelAgent.startProcess(in:)). Local, untracked: Package.resolved, IntegrationTests/Package.resolved, IntegrationTests/LiveAgentServer/Package.resolved now pin FoundationModelsACP b6b265c.
    - tests: `swift test` = 809 tests in 68 suites passed. `swift test --package-path IntegrationTests` = 23 tests in 5 suites passed. The only compiler warning is the allowed "missing creator for mutated node" of mlx-swift_Cmlx.bundle. The integration log also has runtime log lines "A session/update send failed" from the agent at disconnect. They are agent logs, not compiler warnings.
    - open: subtask 5 is not checked. The runs are done, but the push and the message to swissarmyhammer-75 are not done: this step must not commit or push. There is no committed Package.resolved, so there is no Package.resolved change to commit.
    - next: /review ^510qyhn, then commit and push, then send the commit to swissarmyhammer-75.
  timestamp: 2026-11-07T14:20:47.760641+00:00
- actor: claude-code
  id: 01m6v68gx59pf4etr2mvhpx76p
  text: |-
    ### test — stuck
    - evidence: `swift test` root: 809 tests in 68 suites passed, 0 failures; only the allowed MLX "missing creator for mutated node" warning. `swift test --package-path IntegrationTests`: 23 tests in 5 suites passed, 0 failures; only the allowed MLX warning.
    - blocker: `swift format lint -s -r` on GraphQLTunnelTests.swift gives 317 errors: Indentation (296) and LineLength (21). The repo has no `.swift-format` file, so the tool uses its default (2-space indent, 100 columns). The whole repo uses 4-space indent and lines up to 120 columns. The HEAD version of the same file already gives 233 errors (17 LineLength). Unchanged files such as Sources/FoundationModelsACPClient/ACPClient.swift also fail (87 lines of output). The default lint rule and the repo style cannot both be correct. To pass, the whole file must go to 2-space indent, and it would then differ from every other file. I did not change the file and I did not add a config.
    - next: a person decides: add a `.swift-format` file that matches the repo style (4-space indent, 120 columns), or reformat the repo to the default. Then run the test step again.
  timestamp: 2026-11-07T14:23:06.661741+00:00
- actor: claude-code
  id: 01m6v68ytzqgkaf3efyta0t3gm
  text: |-
    ### test — green (orchestrator decision on the lint "stuck")
    - evidence: swift test = 809 tests in 68 suites passed; swift test --package-path IntegrationTests = 23 tests in 5 suites passed; only the allowed MLX warning.
    - lint: the orchestrator added `swift format lint` to the test brief. The project has no .swift-format and its CI runs no format or lint step. GraphQLTunnelTests.swift already gave 233 lint errors at HEAD. Thus lint is not a gate of this project, and the "stuck" outcome of the test step does not apply to this task. The style conflict (default 2-space/100 columns against the 4-space/120 repo style) is a separate decision for a person.
    - next: commit, then /review HEAD~1..HEAD.
  timestamp: 2026-11-07T14:23:20.927931+00:00
- actor: claude-code
  id: 01m6v6asvtkk5d50ay5d8n2wm8
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit ad45b28). 0 findings, 0 confirmed, 0 refuted. 7 validator runs attempted, 0 failed. The engine examined 1 file: GraphQLTunnelTests.swift. The .reviewignore file excluded the 2 .kanban files.
    - next: The orchestrator does the push and sends the commit to swissarmyhammer-75 (the open subtask 5).
  timestamp: 2026-11-07T14:24:21.370821+00:00
- actor: claude-code
  id: 01m6v6b365ammsk30epbn8ra27
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/GraphQLTunnelTests.swift; local pins at FoundationModelsACP b6b265c
    - test: green — swift test 809 passed; swift test --package-path IntegrationTests 23 passed
    - commit: ad45b28
    - review: clean — 0 findings
  timestamp: 2026-11-07T14:24:30.917674+00:00
position_column: done
position_ordinal: ffa680
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

- [x] Move the FoundationModelsACP pin to the fix commit, in IntegrationTests and in IntegrationTests/LiveAgentServer (`swift package update FoundationModelsACP`; Package.resolved is gitignored, so the pin is local).
- [x] Do not change the two server lines. They must not get a gate of their own.
- [x] Check that the root fix has a deterministic test in FoundationModelsACP: a frame that is written before `AgentSideConnection.init` is served by the agent of the factory, and gets no methodNotFound. If it has none, tell swissarmyhammer-75.
- [x] Add one integration check: write `initialize` into the stdin of graphql-tunnel-server before the agent finishes its start-up (write it immediately after the process starts), and expect a valid InitializeResponse. With the old FoundationModelsACP this can fail; note that it is not deterministic in a subprocess, so the deterministic test stays in FoundationModelsACP.
- [x] Run the root tests and the IntegrationTests one time. Push, and send the commit to swissarmyhammer-75. #bug