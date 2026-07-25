# FoundationModelsACPClient — Plan

The **ACP Client role**, implemented as an `@Observable` container so SwiftUI can
drive an ACP agent. Peer to `FoundationModelsACPAgent`: **one package per ACP
role.**

> Target: **OS 27+ only**, matching the family. No `@available` branching.

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
staying SwiftUI-free keeps the container usable from AppKit/UIKit and testable
headlessly, with no view-framework coupling. SwiftUI *uses* this; it isn't *in* it.

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
- **tool calls indexed by `toolCallId`**, so a `toolCallUpdate` mutates in place
  rather than appending a duplicate;
- the **in-flight assistant message** as an append target for
  `agentMessageChunk`, with `agentThoughtChunk` kept **separate** so reasoning can
  be shown, collapsed, or hidden independently;
- `plan`, `availableCommands`, `currentMode`;
- connection state and turn state (idle / running / awaiting-input), plus the last
  `StopReason`.

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

`session/update` is append-only, but the agent's `Transcript` is **rewritten by
compaction**: entries already displayed can cease to exist. A purely accumulating
container goes silently stale, and worsens the longer a session lives — exactly the
desktop case.

So the container must be **rebuildable from `session/load`**, not merely
accumulated, and must reload when the agent signals history invalidation.
`FoundationModelsACP` owes that signal (tracked there); until it exists, this is a
known staleness bug, recorded rather than hidden.

## Capabilities: what a client *owes* the agent

Being a `Client` is not only display. `ClientCapabilities` is
`{ fs: FileSystemCapabilities, session: ClientSessionCapabilities?, terminal: Bool }`,
and every gated method has a default that refuses — so **advertising a capability
is a commitment to implement it**:

| Capability | Methods | Position |
|---|---|---|
| `fs.readTextFile` / `fs.writeTextFile` | `readTextFile`, `writeTextFile` | **v1** — an agent editing code needs them |
| `terminal` | `createTerminal`, `terminalOutput`, `waitForTerminalExit`, `killTerminal`, `releaseTerminal` | **v1 scope decision** — see Decisions |
| elicitation (`form` + `url`) | `elicitation/create`, `elicitation/complete` | blocked on ACP |
| `mcp/connect` etc. | client-hosted MCP servers | out of scope for v1 |

`fs` and `terminal` mean this package touches the user's files and spawns
processes, so both need a **confinement policy** (which roots are reachable, what
the user consented to) and, for terminals, **process-group ownership and reaping**
— the same discipline `FoundationModelsShelltool` applies. Not a thin display
layer.

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
  SwiftUI-free keeps it usable from AppKit/UIKit and headless-testable.
- **`@MainActor` container (decided):** SwiftUI binds main-actor state, and events
  arrive on background tasks, so the hop is explicit and coalesced at that boundary.
- **Projection, never a record (decided):** the container is rebuildable from
  `session/load` and never treated as durable history. The agent's `Transcript` is
  the record; history browsing reads *that*, not this.
- **Terminals in v1 — open.** Advertising `terminal` commits us to process
  ownership and reaping. Decide before advertising; refusing is a valid, honest
  answer that some agents will simply work around.

## Milestones

- [ ] **M0 — Scaffold.** SwiftPM package, dependency on `FoundationModelsACP`
  only, OS 27 floor, CI (build + test).
- [ ] **M1 — Client conformance + observable session state.** `sessionUpdate` lands
  every `SessionUpdate` case; tool calls indexed by `toolCallId`; thought chunks
  separate; `plan` / `availableCommands` / `currentMode`; connection and turn state.
- [ ] **M2 — Coalescing.** Batched, display-cadence flush with a measured test.
- [ ] **M3 — Pending requests.** `requestPermission` as bindable state, answered by
  the UI; cancellation and withdrawal handled.
- [ ] **M4 — Rehydration.** Rebuild from `session/load`; react to history
  invalidation once ACP defines it.
- [ ] **M5 — Filesystem capability.** `readTextFile` / `writeTextFile` with a
  confinement policy and consent model.
- [ ] **M6 — Transports.** In-process pairing plus stdio to an external agent,
  including agent-process ownership and reaping if we spawn it.
- [ ] **M7 — Elicitation.** Form and URL modes as bindable state, honoring the
  spec's consent and no-credentials-back rules. Blocked on ACP.
- [ ] **M8 — Terminals.** Only if the Decisions item lands as yes.

## Testing strategy

- **Stub agent over `InMemoryTransport.pair()`** — drive every `SessionUpdate` case
  and assert final observable state. Deterministic, no model, no network.
- **Identity** — two concurrent same-name tool calls stay distinct and update
  independently; `toolCallUpdate` mutates in place rather than appending.
- **Coalescing** — N rapid chunks produce far fewer than N observable mutations,
  final text byte-identical to concatenation.
- **Rehydration** — a container joining mid-session reconstructs state equal to a
  fresh container loading the same session.
- **Requests** — permission and elicitation set pending state; answering resolves
  the agent's in-flight request; cancellation and withdrawal are clean.
- **Interop** — drive a *foreign* ACP agent binary over stdio, proving the
  no-knowledge-of-our-runtime claim is real rather than aspirational.

## References

- ACP specification — https://agentclientprotocol.com
- ACP elicitation — https://agentclientprotocol.com/protocol/v1/elicitation
- FoundationModelsACP (the wire; `Client` protocol, `InMemoryTransport`) — ../FoundationModelsACP
- FoundationModelsACPAgent (the Agent role peer; see its §9.2 for the derivation
  chain and the compaction problem) — ../FoundationModelsACPAgent
- Observation — https://developer.apple.com/documentation/observation
