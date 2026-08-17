# FoundationModelsACPClient — Plan

The **ACP Client role**, implemented as an `@Observable` container so SwiftUI can
drive an ACP agent. Peer to `FoundationModelsACPAgent`: **one package per ACP
role.**

> Target: **OS 27+ only**, matching the family. No `@available` branching.
> Protocol: **ACP v2 only** — see `FoundationModelsACP`'s Decision: v2 only. v2 is
> **draft**, so this surface moves when the schema does.

## Goal

A SwiftUI app should be able to talk to an ACP agent the same way Zed does — over
the protocol, not through a private back door. This package is that client: it
conforms to `FoundationModelsACP`'s `Client` protocol, lands the agent's
`session/update` stream in observable state, and answers the agent's requests.

Two deployments, one code path:

- **In-process** — `InMemoryTransport.pair()` (already public) wires this client to
  an agent running in the same app. This is how our Mac app uses
  `FoundationModelsACPAgent`.
- **Out-of-process** — stdio to any ACP agent, ours or someone else's.

## Design principle: a client, not *our* client

**This package knows nothing about our runtime.** It depends on
`FoundationModelsACP` (the wire) and `Observation`. It must **not** depend on
`FoundationModelsRouter`, `FoundationModelsACPAgent`, `FoundationModelsMCP`, or the
`FoundationModels` framework.

That constraint is the feature. A client that only knows ACP can drive **any**
conforming agent, so this package is simultaneously our UI layer and a general
Swift ACP client. If it ever needs a type from our agent stack, the interface is
incomplete and the fix belongs upstream in ACP — not in an import here.

**No `import SwiftUI` either.** `Observation` is sufficient for SwiftUI to bind, so
staying SwiftUI-free keeps the container usable from AppKit, from a CLI, and in
headless tests, with no view-framework coupling. The platform floor is macOS 27
only, so UIKit is not a target. SwiftUI *uses* this; it isn't *in* it.

## The record, the interface, the container

Three representations in a strict derivation order. The direction is never
reversed:

```
Transcript (FoundationModels)        THE RECORD — authoritative, non-monotonic
   │  Router projects
SessionEvent / SessionProjection     keyed on Apple's Transcript.ToolCall.id
   │  FoundationModelsACPAgent maps
ACP session/update                   THE INTERFACE — append-only wire stream
   │  InMemoryTransport │ stdio
SwiftUIACPClient (@Observable)       ← this package; SwiftUI binds
```

The container is a **projection of a projection**. It is not a database and never
the source of truth: the agent's `Transcript` is. Everything below follows from
that.

**One identity, end to end.** ACP's `toolCallId` is, upstream, Apple's own
`Transcript.ToolCall.id` — and also our `OperationEvent.correlationID` and (for MCP
work) the MCP call handle. That single stable key is what `ForEach` needs, and what
makes two concurrent same-name tool calls distinguishable.

## The container

`SwiftUIACPClient` — `@MainActor @Observable`, conforming to `Client`. Per session
it holds:

- an **ordered entry list**, stably identified for `ForEach`;
- **messages keyed by `messageId`** — required and **agent-generated** in v2,
  because *"the Agent owns session history, so it is the single source of message
  identity."* The container never mints identity;
- **tool calls indexed by `toolCallId`**. In v2 `tool_call` create is gone:
  `tool_call_update` is an **upsert**, so the first update bearing a new id creates
  the entry and later ones patch it. `tool_call_content_chunk` appends content
  items;
- **display terminals keyed by `terminalId`** (see below);
- `plan` entries per `planId`, `availableCommands`, and **config options**
  (v2 replaced modes with config options: `mode`, `model`, `model_config`,
  `thought_level`);
- **session metadata and usage** from `session_info_update` and `usage_update`;
- **turn state read from the protocol, not inferred** — `state_update` gives
  `running`, `idle` (carrying `stopReason`), and **`requires_action`**;
- connection state.

### Upsert semantics are the tricky part

v2 messages are **whole-message upserts** with three-state `content`: **omitted
means unchanged, `null` or `[]` clears, a concrete array replaces.** The `*_chunk`
variants append. Tool-call content behaves the same way — a `content` field
replaces accumulated content and subsequent chunks append to the replacement.

Conflating those four cases silently corrupts what the user sees, so the container
implements them exactly and tests each separately. This is also what makes v2
history *correctable* rather than append-only, which is why the compaction
staleness problem largely evaporates (below).

### Display terminals are rendered, never driven

**Certain:** all five client `terminal/*` methods are removed in v2. This package
never runs a terminal.

**Verified (2026-08-17): the display-terminal surface is real in v2 as
generated.** An earlier version of this plan said the schema did not show it.
That was stale. The evidence:

- the vendored schema `FoundationModelsACP/Schema/acp-v2.json` contains
  `"const": "terminal_update"` (line 3492), `"const": "terminal_output_chunk"`
  (line 3508), and a `"const": "terminal"` content variant (line 872);
- the generated `SessionUpdate` has `case terminalUpdate(TerminalUpdate)` and
  `case terminalOutputChunk(TerminalOutputChunk)`;
- the generated tool-call content union has `case terminal(Terminal)` — "a
  display-only reference to an agent-owned terminal."

So this package **renders** the terminals the agent owns: `terminal_update`
upserts keyed by `terminalId`, `terminal_output_chunk` appends RFC 4648 base64
bytes, and `{"type": "terminal", "terminalId": …}` content references resolve
against the terminal index. The surface stays display-only — no input, resize,
interrupt, kill, wait, release, or execution semantics. M5 implements it.

The schema also puts a **`terminalId` field on `CommandPermissionSubject`** —
*"the associated terminal, when already known"* — so a permission request for a
command can point at a terminal already in the index. M3 covers that reference.

### Pending requests are state, not callbacks

`requestPermission` and elicitation arrive as *requests the user must answer*. A
callback cannot be rendered. So each becomes **observable pending state** the UI
binds to and resolves — a permission prompt is a view. The container holds the
continuation and completes it when the UI answers, with cancellation and
agent-side withdrawal handled.

This is also where ACP's elicitation modes land: **form mode** renders
`requestedSchema` (flat primitives/enums); **URL mode** must display the target
host and obtain consent before navigation, must not carry credentials back over
ACP, and closes on `elicitation/complete`. Those are spec obligations, not UI
preferences.

### Coalescing is a requirement, not an optimization

`agentMessageChunk` arrives at token rate. Applying each one to an `@Observable` on
the main actor thrashes SwiftUI. The container batches deltas and flushes on a
display-rate cadence, appending into the in-flight message instead of rebuilding
arrays. **This gets measured, not assumed** — a test asserts N chunks produce far
fewer than N observable mutations while the final text stays byte-identical to
plain concatenation.

### Rehydration, because the record is non-monotonic

The agent's `Transcript` is **rewritten by compaction**: entries already displayed
can cease to exist. A container that only ever appends goes silently stale, and
worsens the longer a session lives — exactly the desktop case.

**v2 answers this directly, which is a large part of why we target it.**
`session/resume` with `replayFrom: {"type": "start"}` makes full history replay a
**first-class request** — the agent replays history as ordinary session updates when
asked. Combined with whole-message upserts that can replace or clear content, and
agent-owned `messageId`, the protocol now says what the record says.

So the container **rebuilds by asking**, and needs no bespoke invalidation signal:

- build full state from a `replayFrom: start` resume, discarding prior accumulation;
- rebuild must be **idempotent** — resuming twice changes nothing;
- a container joining mid-session must reach the same state as one that streamed
  from the beginning.

Nothing in v2 pushes a "you should resume" signal after a compaction, and none is
needed. The answer is **policy, not protocol**: this container resumes with full
replay on reconnect, and whenever the app chooses to resynchronize.

## What a v2 client owes the agent: almost nothing

This is the single biggest reason v2 is worth targeting for this package. v1 made a
client responsible for the agent's file access and process execution. **v2 deletes
both.**

- `fs/read_text_file` and `fs/write_text_file`: **removed.** Agents reach the
  client's files through **MCP** instead.
- All five `terminal/*` methods: **removed.** Agents use **MCP** for execution, and
  own their display terminals themselves.
- `clientCapabilities.fs` and `.terminal`: **removed.** And *"stable v2 defines no
  standard client capability fields."*

So the stable v2 Client role is **two entry points**: consume `session/update`
and answer `session/request_permission`. This is verified against the vendored
package: `public protocol Client` has exactly those two members. Elicitation is
**unstable-only** — the v2 schema contains no elicitation methods, and the
generated `MethodTable` lists `elicitation/*` only as unstable method info, with
nothing on the client surface to gate behind a capability.

That is what makes this package honestly a **UI projection**: no confinement
policy, no path-traversal defense, no process-group ownership, no reaping. The
earlier plan carried all of that as v1 scope; v2 removes the requirement rather
than us declining it.

**Where that work went:** into MCP, and therefore into `FoundationModelsMCP` and
the agent. Our agent already has `FoundationModelsFileTool` and
`FoundationModelsShelltool` with their existing confinement and process discipline;
v2's design says that is the right side of the protocol for them to live on. The
capability question is settled: `ClientCapabilities` carries only `_meta`, stable
v2 defines no standard client capability fields, and elicitation waits upstream
as an unstable surface (M7 tracks it).

## Transports, and who owns the agent process

- **In-process:** `InMemoryTransport.pair()`. No spawning, no framing concerns.
- **Out-of-process:** stdio to an agent binary — which means **this package may
  spawn and own the agent process**, with the same no-leak obligations that appear
  everywhere else in this family: process-group spawn, termination on shutdown,
  reaping, and an honest statement of what is not guaranteed under `SIGKILL`.

## Decisions

- **Own package (decided):** peer to `FoundationModelsACPAgent`, one package per
  ACP role. Keeps `FoundationModelsACP`'s wire target portable — SwiftUI and
  `Observation` are Apple-only, and the wire should stay usable anywhere.
- **Depends on the wire only (decided):** `FoundationModelsACP` + `Observation`.
  Never Router, ACPAgent, MCP, or the FoundationModels framework. A needed type
  from our stack means the *interface* is incomplete.
- **No `import SwiftUI` (decided):** `Observation` suffices for binding; staying
  SwiftUI-free keeps it usable from AppKit, from a CLI, and headless-testable.
  The macOS 27 floor makes UIKit a non-target.
- **`@MainActor` container (decided):** SwiftUI binds main-actor state, and events
  arrive on background tasks, so the hop is explicit and coalesced at that boundary.
- **Projection, never a record (decided):** the container is rebuildable from
  `session/resume` with `replayFrom: start` and never treated as durable history.
  The agent's `Transcript` is the record; history browsing reads *that*, not this.
- **v2 only (decided):** matches `FoundationModelsACP`. No v1 client surface. v2 is
  draft, so this package moves with it.
- **This package never runs a terminal, but renders display terminals (decided;
  verified).** v2 removed the five client `terminal/*` methods outright, so
  process discipline stays inside the agent where `FoundationModelsShelltool`
  already implements it. The *display-only* successor **is present** in the
  vendored schema and the generated code (see "Display terminals are rendered,
  never driven" for the evidence), so this package renders it and never drives it.
- **No filesystem surface (decided by v2):** `fs/*` is gone; agents use MCP. This
  package does not touch the user's files, so it needs no confinement policy.

## Milestones

- [ ] **M0 — Scaffold.** SwiftPM package, dependency on `FoundationModelsACP`
  only, OS 27 floor, CI (build + test).
- [ ] **M1 — Client conformance + observable session state.** `sessionUpdate` lands
  all 16 generated `SessionUpdate` cases plus `unknown`; messages upserted by
  agent-generated `messageId` with exact three-state `content` handling; tool
  calls upserted by `toolCallId`; thought messages separate; turn state from
  `state_update`; `planUpdate` / `availableCommandsUpdate` / `configOptionUpdate`
  / `sessionInfoUpdate` / `usageUpdate`; connection state.
- [ ] **M2 — Coalescing.** Batched, display-cadence flush with a measured test.
- [ ] **M3 — Pending requests.** `requestPermission` as bindable state, answered by
  the UI; the `.toolCall` and `.command` subjects (with `terminalId`) modeled;
  cancellation and withdrawal handled.
- [ ] **M4 — Rehydration.** Rebuild from `session/resume` with `replayFrom: start`;
  resume-on-reconnect is policy, and no bespoke invalidation signal is needed.
- [ ] **M5 — Render display terminals.** Verification is done — the surface exists
  in the schema and the generated code. Render `terminal_update` /
  `terminal_output_chunk` / `terminal` content references (base64 bytes including
  non-UTF8, snapshot-replaces-vs-chunk-appends, `exitStatus`), driven by the stub
  agent like every other `SessionUpdate` case.
- [ ] **M6 — Transports.** In-process pairing plus stdio to an external agent,
  including agent-process ownership and reaping if we spawn it.
- [ ] **M7 — Elicitation.** Form and URL modes as bindable state, honoring the
  spec's consent, host-display, and no-credentials-back rules. Blocked upstream:
  elicitation is unstable-only in v2 (ACP's M8 tracks stabilization).
- **Filesystem: not applicable.** v2 removed `fs/*` from the client role entirely.
  Listed so its absence reads as the protocol's decision rather than an omission.

## Testing strategy

- **Stub agent over `InMemoryTransport.pair()`** — drive every `SessionUpdate` case
  and assert final observable state. Deterministic, no model, no network.
- **Identity** — two concurrent same-name tool calls stay distinct and update
  independently; `toolCallUpdate` mutates in place rather than appending.
- **Coalescing** — N rapid chunks produce far fewer than N observable mutations,
  final text byte-identical to concatenation.
- **Rehydration** — a container joining mid-session reconstructs state equal to a
  fresh container resuming the same session with full replay.
- **Requests** — permission and elicitation set pending state; answering resolves
  the agent's in-flight request; cancellation and withdrawal are clean.
- **Interop** — drive a *foreign* ACP agent binary over stdio, proving the
  no-knowledge-of-our-runtime claim is real rather than aspirational.

## References

- ACP specification — https://agentclientprotocol.com
- ACP elicitation (v1 doc; v2 keeps elicitation unstable-only, see M7) —
  https://agentclientprotocol.com/protocol/v1/elicitation
- FoundationModelsACP (the wire; `Client` protocol, `InMemoryTransport`) — ../FoundationModelsACP
- FoundationModelsACPAgent (the Agent role peer; see its §9.2 for the derivation
  chain and the compaction problem) — ../FoundationModelsACPAgent
- Observation — https://developer.apple.com/documentation/observation
