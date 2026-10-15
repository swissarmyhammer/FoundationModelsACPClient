---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50drf2jqf19k1h8btptab1p
  text: |-
    ### Follow-up for AgentViewKit (part 3 of the accepted design)
    - `ClientCapabilities.agentViewKit` (AgentViewKit `KitInitializeRequest.swift`) is a second advertiser with its own form and url value. Change: make it from `ACPClient.capabilities(for: .interactive)`, so that the two values cannot drift.
    - `InitializeRequest.makeAgentViewKitRequest(info:terminalAuthRunner:)` can get a `userPresence: ACPClient.UserPresence = .interactive` parameter. AgentViewKit always has a UI, so in practice it stays interactive.
    - No other change is necessary. AgentViewKit uses ConnectionModel, so it gets the immediate cancel with the `_meta` reason with no change.

    ### implement — changed
    - API: `ACPClient.UserPresence` (`interactive`, `headless`) and `ACPClient.capabilities(for:)`. `advertisedCapabilities` stays the same value.
    - Reasons:
      - `ACPClient.noUserPresentReason` is "no user is present", the same text as Extras.
      - `ACPClient.unadvertisedElicitationModeReason` is for a mode that was not advertised, when the other mode was.
    - `_meta` key: `ACPClient.elicitationReasonMetaKey` = "reason". The response is `{"action":"cancel","_meta":{"reason":"..."}}`.
    - Model: `initialize(_:)` records `request.capabilities.elicitation`, and `connect` resets it. After a successful initialize, ModelClient answers an elicitation of a mode that was not advertised with an immediate cancel and the reason. It makes no pending state, logs one line, and the span shows routed = false. Before initialize, the model refuses nothing.
    - Tests: `ElicitationUserPresenceTests` (5 tests) and 2 tests in `ACPClientTests`.
    - Full run: 549 tests in 44 suites pass. IntegrationTests builds.
  timestamp: 2026-10-15T18:38:57.618549+00:00
position_column: done
position_ordinal: ff80
title: 'Elicitation phase 2, task 28: make the elicitation capability an explicit client setting (user presence)'
---
Source: elicitation-plan.md sections 0, 2, 7 (task 28) and 9 (phase 2).

Today `ACPClient.advertisedCapabilities` is one static value with elicitation form and URL. A host with no UI (for example `acp-agent run` and `acp-print`) must build its own `ClientCapabilities`, else a question of the agent waits for ever.

Goal: the host says whether a user is present. With no user, the client advertises no `elicitation` capability. The change is additive: the default keeps the current behavior for UI hosts.

Steps:
- Send a short design to the step owner, and get acceptance before code.
- Implement the accepted design, with fixed-order tests.
- Run the full suite one time, then commit.
- Push after the step owner accepts.
- Record the follow-up change for AgentViewKit (`ClientCapabilities.agentViewKit`).

#elicitation-phase-2