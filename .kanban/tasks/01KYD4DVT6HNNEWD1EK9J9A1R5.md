---
comments:
- actor: claude-code
  id: 01m0ac9kv876b1xgf40qcv64cf
  text: |-
    Research done. Discoveries:

    - The wire package moved to ACP stable v2. The card gives v1 case names. The real `SessionUpdate` union has 17 cases: userMessageChunk, userMessage, agentMessageChunk, agentMessage, agentThoughtChunk, agentThought, stateUpdate, toolCallContentChunk, toolCallUpdate, terminalUpdate, terminalOutputChunk, planUpdate, availableCommandsUpdate, configOptionUpdate, sessionInfoUpdate, usageUpdate, and unknown. The container must land all of them. The v1 names map as: toolCall -> toolCallUpdate (upsert), plan -> planUpdate, currentModeUpdate -> configOptionUpdate.
    - The v2 `Client` protocol has exactly two required methods: sessionUpdate and requestPermission. Stable v2 removed the fs/* and terminal/* client methods. The acceptance criterion about capability-gated refusing defaults is satisfied by construction: no gated client method exists in v2, so the client cannot advertise one. requestPermission gets a minimal answer (outcome .cancelled) until M3 makes it bindable pending state.
    - Turn state comes from the stateUpdate case: running -> running, idle -> idle (with an optional StopReason), requiresAction -> awaiting input.
    - The wire package ships `SessionUpdateAggregator` (public). It applies the v2 upsert rules: chunks append, whole-message upserts replace, tool calls fold by toolCallId with PatchField semantics, plans replace by planId, terminals accumulate output. The container will reuse it instead of a second copy of the fold rules. An update for an unknown toolCallId ADOPTS (first sighting creates) - this matches the aggregator and the spec, and a test asserts it.
    - Test plan: direct-drive unit tests call sessionUpdate on the MainActor; one wire test drives a stub Agent over InMemoryTransport.pair() with AgentSideConnection/ClientSideConnection. The connection read loop awaits each notification inline and in wire order, so when prompt() returns, every scripted update has landed. This makes the wire test deterministic without polling.
    - Validators read and noted (54 rules): doc comments on every public declaration, no force unwrap in non-test code, no magic numbers, value semantics, state as enum, explicit access control, periphery dead-code marker contract, honest tests.
  timestamp: 2026-08-18T12:07:17.608289+00:00
- actor: claude-code
  id: 01m0acmk562dwtqmffeq20z22h
  text: |-
    Implementation landed with /tdd (red first, then green).

    RED: wrote 25 new tests before any production code. `swift build --build-tests` failed with "cannot find type 'SwiftUIACPClient' in scope", which is the expected failure for a missing feature.

    GREEN: added three source files, then all 27 tests passed with zero warnings.

    Files:
    - Sources/FoundationModelsACPClient/SwiftUIACPClient.swift - the @MainActor @Observable container. It conforms to `Client`, holds one ACPSessionState per session (created on the first update), and holds the observable ConnectionState (the M6 transport work will set it). requestPermission answers the `cancelled` outcome as a documented placeholder until M3 lands bindable pending state.
    - Sources/FoundationModelsACPClient/ACPSessionState.swift - the per-session observable state. `apply(_:)` lands every SessionUpdate case. It reuses the wire package's SessionUpdateAggregator for the upsert rules, so this package holds no second copy of them. TurnState (idle / running / awaitingInput) and lastStopReason come from stateUpdate.
    - Sources/FoundationModelsACPClient/SessionEntry.swift - the ordered-entry identity type. Entries carry identity only; content lives in the state keyed by the same identity, so updates mutate in place and ForEach identity never churns.

    Tests:
    - Tests/.../SessionStateTests.swift - 23 direct-drive tests through the Client conformance: one per update case, tool-call fold and adopt behavior, all five ToolCallStatus values with pending distinct from inProgress, interleaved thought/message separation, entry identity stability, two sessions, observation firing, permission answer.
    - Tests/.../WireConformanceTests.swift - a stub Agent over InMemoryTransport.pair() sends one update for every SessionUpdate case in one prompt turn; the test asserts the final state for all of them.
    - Tests/.../SessionUpdateFixtures.swift - shared builders.

    Decisions recorded:
    - A toolCallUpdate for an unknown id is ADOPTED (first sighting creates), matching the aggregator and the v2 spec. A test asserts it.
    - An unrecognized SessionUpdate changes no state. A test asserts it.
    - The capability criterion is satisfied by construction: stable v2 has no capability-gated client method, so nothing can be accidentally advertised. The doc comment on SwiftUIACPClient states this.

    Evidence: `swift test` -> "Test run with 27 tests in 0 suites passed". Zero failures, zero warnings, zero skips.
  timestamp: 2026-08-18T12:13:17.350133+00:00
- actor: claude-code
  id: 01m0acmrem7qjyxnrjvc4xhd2m
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPClient/SwiftUIACPClient.swift, Sources/FoundationModelsACPClient/ACPSessionState.swift, Sources/FoundationModelsACPClient/SessionEntry.swift, Tests/FoundationModelsACPClientTests/SessionStateTests.swift, Tests/FoundationModelsACPClientTests/WireConformanceTests.swift, Tests/FoundationModelsACPClientTests/SessionUpdateFixtures.swift; `swift test` passed 27 tests, 0 failures, 0 warnings, 0 skips
    - next: /review
  timestamp: 2026-08-18T12:13:22.772203+00:00
- actor: claude-code
  id: 01m0acq3s75arskw0zpk82hc6p
  text: |-
    ### test — green
    - evidence: `swift build` (clean, from scratch) — 0 warnings, build complete. `swift test` — 27 tests, 0 failures, 0 skipped.
    - next: no action needed.
  timestamp: 2026-08-18T12:14:39.911913+00:00
depends_on:
- 01KYD4DVSQ0ZGYGYBS8T95TAX5
position_column: doing
position_ordinal: '80'
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

Note from implementation: the wire package now speaks ACP stable v2, so the case names above map as `toolCall` -> `toolCallUpdate` (upsert), `plan` -> `planUpdate`, and `currentModeUpdate` -> `configOptionUpdate`. The real union has 17 cases and the container lands all of them.

## Acceptance Criteria

- [x] Conforms to `Client`; every `SessionUpdate` case updates observable state.
- [x] Tool calls keyed by `toolCallId`; `toolCallUpdate` mutates in place.
- [x] Thought chunks are separately addressable from message text.
- [x] `plan` / `availableCommands` / `currentMode` / connection / turn state all observable.
- [x] All `ToolCallStatus` values represented, `pending` distinct from `inProgress`.
- [x] Capability-gated methods we do not implement keep their refusing defaults (no accidental advertisement). Satisfied by construction: stable v2 defines no capability-gated client method, so the client cannot advertise one.

## Tests

- [x] Drive over `InMemoryTransport.pair()` against a stub agent; assert final state for every `SessionUpdate` case.
- [x] Two concurrent same-name tool calls stay distinct and update independently.
- [x] A `toolCallUpdate` for a known id mutates rather than appends; for an unknown id, the documented behavior holds (adopt or ignore -- decide and assert). Decision: adopt, asserted.
- [x] Thought and message chunks interleaved stay separated.
- [x] Entry identity is stable across updates (no `ForEach` churn).

## Workflow

- Use `/tdd` -- write failing tests first.
