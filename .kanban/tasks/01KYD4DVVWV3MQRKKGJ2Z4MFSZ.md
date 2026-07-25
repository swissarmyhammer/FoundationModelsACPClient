---
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: todo
position_ordinal: '8380'
title: 'M3 Pending requests as bindable state: permission now, elicitation later'
---
## What

`plan.md` -> **Pending requests are state, not callbacks**.

`requestPermission` (and later elicitation) is a *request the user must answer*. A callback cannot be rendered, so it must become **observable pending state** the UI binds to and resolves.

- Hold the pending request plus its continuation; complete it when the UI answers.
- Model `RequestPermissionRequest`'s `options: [PermissionOption]` and its `toolCall: ToolCallUpdate` context, so the UI can show *what* is being permitted.
- Handle **cancellation** (the agent gives up, the turn is cancelled, the connection drops) without leaking a continuation or leaving a ghost prompt on screen.
- Support more than one outstanding request, or explicitly document and enforce one-at-a-time.

Elicitation is the same shape and lands here once `FoundationModelsACP` ships the surface: **form mode** renders `requestedSchema` (flat primitives/enums); **URL mode** must display the target host and obtain consent before navigation, must never carry credentials back over ACP, and closes on `elicitation/complete`. Those are spec obligations. Advertise `clientCapabilities.elicitation` only for modes actually implemented -- requesting an unsupported mode is a `-32602`, and over-advertising causes exactly that.

## Acceptance Criteria

- [ ] `requestPermission` sets observable pending state carrying options and tool-call context.
- [ ] Answering from the UI resolves the agent's in-flight request with the chosen option.
- [ ] Cancellation/disconnect clears pending state and leaks no continuation.
- [ ] Concurrency policy (multiple vs. single outstanding) is implemented and documented.
- [ ] Capabilities advertise only what is implemented.

## Tests

- [ ] A stub agent's permission request appears as pending state; answering it resolves the agent's call with the selected option.
- [ ] Cancelling the agent's request clears the prompt and leaves no suspended continuation (assert no leak).
- [ ] Connection drop while pending clears state cleanly.
- [ ] Two overlapping requests behave per the documented policy.
- [ ] Advertised capabilities match implemented methods.

## Workflow

- Use `/tdd` -- write failing tests first.
