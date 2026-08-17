---
comments:
- actor: wballard
  id: 01kyd5cnt961btjyydzt0kwxh5
  text: |-
    ## Reframed for ACP v2 -- permission restructured, elicitation now stable

    **`session/request_permission` params changed.** v2 separates prompt copy from context:

    - required **`title`** -- the human-readable prompt text;
    - optional **`description`** -- supporting copy;
    - optional **`subject`**, a tagged union:
      - `tool_call` -- payload is a `ToolCallUpdate` upsert shape,
      - `command` -- self-contained, with required `command`, required **absolute** `cwd`, and optional `toolCallId` / `terminalId`.

    `options` and the response shape are unchanged. So the UI has real copy to render (`title` / `description`) rather than having to synthesize a prompt from the tool call -- bind those directly.

    **Elicitation is stable in v2** (it was unstable in v1), so this task is no longer blocked on a hand-authored addendum -- only on ACP's M8 generating it. `elicitation/create` is a Client method; `elicitation/complete` a Client notification reporting that a **URL-mode** interaction finished.

    **`requires_action` matters here.** v2's `state_update` has a `requires_action` state meaning foreground work is blocked waiting on the user. That is the protocol telling the UI exactly what this task's pending state represents, so the two should agree: when a permission or elicitation is outstanding, the session's observed state should be `requires_action`. Assert that correspondence rather than tracking two independent notions of "waiting."

    Security obligations for URL mode are the client's and unchanged: display the target host and obtain consent before navigating, never carry credentials back over ACP, no prefetching. Advertise only the modes actually implemented -- an unsupported mode request is a `-32602`.
  timestamp: 2026-07-25T17:32:57.545591+00:00
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: todo
position_ordinal: '8380'
title: M3 Permission requests as bindable pending state
---
## What

`plan.md` -> **Pending requests are state, not callbacks**.

`requestPermission` is a *request the user must answer*. A callback cannot be rendered, so it must become **observable pending state** the UI binds to and resolves.

- Hold the pending request plus its continuation; complete it when the UI answers.
- Model the real `RequestPermissionRequest` shape: `options: [PermissionOption]` (at least one), `sessionId`, `title: String`, `description: String?`, and `subject: RequestPermissionSubject?`.
- `RequestPermissionSubject` is an enum: `.toolCall(ToolCallPermissionSubject)` and `.command(CommandPermissionSubject)`. The `.command` case carries the command string and an optional `terminalId` -- "the associated terminal, when already known" -- which resolves against the M5 terminal index.
- Handle **cancellation** (the agent gives up, the turn is cancelled, the connection drops) without leaking a continuation or leaving a ghost prompt on screen.
- Support more than one outstanding request, or explicitly document and enforce one-at-a-time.

Elicitation is **not** in this task. It is unstable-only in v2 and is tracked as its own M7 task, blocked on the upstream ACP surface stabilizing. Also note: v2's `ClientCapabilities` carries only `_meta` -- there is no capability field to advertise, so this task has no capability work.

## Acceptance Criteria

- [ ] `requestPermission` sets observable pending state carrying `options`, `title`, `description`, and `subject`.
- [ ] Answering from the UI resolves the agent's in-flight request with the chosen option.
- [ ] A `.toolCall` subject links the prompt to the tool call it concerns.
- [ ] A `.command` subject exposes the command and its optional `terminalId`.
- [ ] Cancellation/disconnect clears pending state and leaks no continuation.
- [ ] Concurrency policy (multiple vs. single outstanding) is implemented and documented.

## Tests

- [ ] A stub agent's permission request appears as pending state; answering it resolves the agent's call with the selected option.
- [ ] A `.command` subject with a `terminalId` resolves to the matching terminal in the index; an unknown `terminalId` degrades gracefully.
- [ ] Cancelling the agent's request clears the prompt and leaves no suspended continuation (assert no leak).
- [ ] Connection drop while pending clears state cleanly.
- [ ] Two overlapping requests behave per the documented policy.

## Workflow

- Use `/tdd` -- write failing tests first.
