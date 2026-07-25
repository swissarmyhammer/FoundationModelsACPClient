---
depends_on:
- 01KYD4DVSQ0ZGYGYBS8T95TAX5
position_column: todo
position_ordinal: '8180'
title: 'M1 Client conformance: land every SessionUpdate case in observable state'
---
## What

`plan.md` -> **M1** and **The container**.

`SwiftUIACPClient` -- `@MainActor @Observable`, conforming to `FoundationModelsACP.Client`. `sessionUpdate` lands every `SessionUpdate` case:

`userMessageChunk`, `agentMessageChunk`, `agentThoughtChunk`, `toolCall`, `toolCallUpdate`, `plan`, `availableCommandsUpdate`, `currentModeUpdate`.

State to hold:

- an **ordered entry list**, stably identified for SwiftUI `ForEach`;
- **tool calls indexed by `toolCallId`** so `toolCallUpdate` mutates in place instead of appending a duplicate. This id is, upstream, Apple's own `Transcript.ToolCall.id` -- the single identity that also serves as `OperationEvent.correlationID` and, for MCP work, the MCP call handle. It is the reason two concurrent same-name tool calls stay distinguishable;
- the **in-flight assistant message** as an append target, with `agentThoughtChunk` kept **separate** so reasoning can be shown, collapsed, or hidden independently;
- `plan`, `availableCommands`, `currentMode`;
- connection state and turn state (idle / running / awaiting-input) plus the last `StopReason`.

Render `ToolCall`'s full payload -- `status`, `kind`, `content`, `locations`, `rawInput`, `rawOutput`, `title` -- since a UI needs all of it. Note ACP's `ToolCallStatus` includes `pending` (queued) as distinct from `inProgress` (running, including a **detached** long-running MCP call that stays `inProgress` across turns).

Coalescing is deliberately **not** in this task -- M2 -- so correctness lands before performance.

## Acceptance Criteria

- [ ] Conforms to `Client`; every `SessionUpdate` case updates observable state.
- [ ] Tool calls keyed by `toolCallId`; `toolCallUpdate` mutates in place.
- [ ] Thought chunks are separately addressable from message text.
- [ ] `plan` / `availableCommands` / `currentMode` / connection / turn state all observable.
- [ ] All `ToolCallStatus` values represented, `pending` distinct from `inProgress`.
- [ ] Capability-gated methods we do not implement keep their refusing defaults (no accidental advertisement).

## Tests

- [ ] Drive over `InMemoryTransport.pair()` against a stub agent; assert final state for every `SessionUpdate` case.
- [ ] Two concurrent same-name tool calls stay distinct and update independently.
- [ ] A `toolCallUpdate` for a known id mutates rather than appends; for an unknown id, the documented behavior holds (adopt or ignore -- decide and assert).
- [ ] Thought and message chunks interleaved stay separated.
- [ ] Entry identity is stable across updates (no `ForEach` churn).

## Workflow

- Use `/tdd` -- write failing tests first.
