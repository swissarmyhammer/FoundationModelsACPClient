---
comments:
- actor: wballard
  id: 01kyd5cnsr5n5ygm56041f4t43
  text: |-
    ## Reframed for ACP v2 -- the update surface changed shape

    This task was written against v1's `SessionUpdate`. v2 restructures it, and three changes affect the container's core data model:

    **1. `tool_call` create is gone.** `tool_call_update` is an **upsert**: the first update bearing a new `toolCallId` creates the entry, later ones patch it. So "index by id, mutate in place" is no longer an optimization -- it is the only correct implementation. New `tool_call_content_chunk` appends individual content items.

    **2. Messages carry a required, agent-generated `messageId`.** *"The Agent owns session history, so it is the single source of message identity."* Key messages by it; the container must never mint identity. This is our "transcript is the record" invariant written into the protocol.

    **3. Whole-message upserts with three-state `content`.** `user_message` / `agent_message` / `agent_thought` take full arrays: **omitted = unchanged, `null` or `[]` = cleared, concrete array = replaced.** The `*_chunk` variants append. Tool-call content is the same: a `content` field replaces, and subsequent chunks append to the replacement.

    Conflating those four cases silently corrupts what the user sees, so implement and test each separately.

    **Also changed:**

    - **Turn state comes from the protocol now.** `state_update` gives `running`, `idle` (carrying `stopReason`), and **`requires_action`** (blocked on the user). Do not infer turn state -- read it. `requires_action` is the protocol-level representation of a pending permission or elicitation, which v1 had no way to express.
    - `current_mode_update` is **removed**; modes became **config options** (`config_option_update`, with categories `mode` / `model` / `model_config` / `thought_level`).
    - `plan` became **`plan_update`** with a required `planId` and a tagged `type: "items"`; each update **replaces** that plan's entries.
    - `status` enums gain `cancelled` and become **extensible** -- unknown values must be preserved, not coerced.
    - Slash-command `input` specs gain a required `type: "text"` discriminator.
    - Display terminals are their own task (M5).

    Unchanged and still the point: `toolCallId` is the stable `ForEach` key, and upstream it is Apple's own `Transcript.ToolCall.id`.
  timestamp: 2026-07-25T17:32:57.528274+00:00
depends_on:
- 01KYD4DVSQ0ZGYGYBS8T95TAX5
position_column: todo
position_ordinal: '8180'
title: 'M1 Client conformance: land every SessionUpdate case in observable state'
---
## What

`plan.md` -> **M1** and **The container**.

`SwiftUIACPClient` -- `@MainActor @Observable`, conforming to `FoundationModelsACP.Client`. `sessionUpdate` lands every generated `SessionUpdate` case. The generated enum (`Unions.generated.swift`) has 16 cases plus `unknown`:

`userMessageChunk`, `userMessage`, `agentMessageChunk`, `agentMessage`, `agentThoughtChunk`, `agentThought`, `stateUpdate`, `toolCallContentChunk`, `toolCallUpdate`, `terminalUpdate`, `terminalOutputChunk`, `planUpdate`, `availableCommandsUpdate`, `configOptionUpdate`, `sessionInfoUpdate`, `usageUpdate`, plus `unknown`.

State to hold:

- an **ordered entry list**, stably identified for SwiftUI `ForEach`;
- **messages keyed by `messageId`** -- `userMessage` / `agentMessage` / `agentThought` are whole-message upserts. The agent generates `messageId`; the container never mints identity. Message `content` is `PatchField<[ContentBlock]>` with three states: **omitted keeps the current content, `null` or `[]` clears it, a concrete array replaces it.** The `*_chunk` variants append to the current content. Implement each state exactly -- conflating them corrupts what the user sees;
- **tool calls indexed by `toolCallId`**. v2 has no `tool_call` create: `toolCallUpdate` is an **upsert** -- the first update with a new id creates the entry, and later updates patch it. `toolCallContentChunk` appends content. A `content` field on an update replaces accumulated content, and later chunks append to the replacement. This id is, upstream, Apple's own `Transcript.ToolCall.id` -- the identity that keeps two concurrent same-name tool calls distinguishable;
- thought messages (`agentThought` / `agentThoughtChunk`) kept **separate** so reasoning can be shown, collapsed, or hidden independently;
- **turn state from `stateUpdate`**, never inferred: `running`, `idle` (carries `stopReason`), `requiresAction`;
- `planUpdate` entries per `planId`; `availableCommandsUpdate`; **config options** from `configOptionUpdate` (v2 replaced modes: `mode`, `model`, `model_config`, `thought_level`);
- session metadata from `sessionInfoUpdate` and usage/cost from `usageUpdate`;
- `terminalUpdate` / `terminalOutputChunk` route into a terminal index keyed by `terminalId`. Full rendering semantics (base64 decode, snapshot-replace) are M5;
- connection state;
- an `unknown` case is ignored safely and does not corrupt state.

Render `ToolCallUpdate`'s full payload -- `status`, `kind`, `content`, `locations`, `rawInput`, `rawOutput`, `title` -- since a UI needs all of it. `ToolCallStatus` includes `pending` (queued) as distinct from `inProgress` (running, including a **detached** long-running MCP call that stays `inProgress` across turns).

Coalescing is deliberately **not** in this task -- M2 -- so correctness lands before performance.

## Acceptance Criteria

- [ ] Conforms to `Client`; all 16 `SessionUpdate` cases plus `unknown` update observable state.
- [ ] Messages keyed by agent-generated `messageId`; the container never mints identity.
- [ ] `PatchField` three-state content semantics exact: omitted keeps, `null`/`[]` clears, array replaces; chunks append.
- [ ] Tool calls keyed by `toolCallId`; `toolCallUpdate` upserts -- first update creates, later updates patch.
- [ ] Thought messages are separately addressable from response messages.
- [ ] `stateUpdate` drives turn state: `running` / `idle` (with `stopReason`) / `requiresAction`.
- [ ] `planUpdate` / `availableCommandsUpdate` / `configOptionUpdate` / `sessionInfoUpdate` / `usageUpdate` / connection state all observable.
- [ ] All `ToolCallStatus` values represented, `pending` distinct from `inProgress`.

## Tests

- [ ] Drive over `InMemoryTransport.pair()` against a stub agent; assert final state for every `SessionUpdate` case.
- [ ] One test per `PatchField` state: omitted keeps, `null` clears, `[]` clears, a concrete array replaces -- plus chunks append after a replace.
- [ ] Two concurrent same-name tool calls stay distinct and update independently.
- [ ] A `toolCallUpdate` for a known id patches in place; for a new id, it creates the entry.
- [ ] Thought and message chunks interleaved stay separated.
- [ ] Entry identity is stable across updates (no `ForEach` churn).
- [ ] An `unknown` update leaves existing state unchanged.

## Workflow

- Use `/tdd` -- write failing tests first.
