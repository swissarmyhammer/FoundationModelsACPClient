# FoundationModelsACPClient

The [Agent Client Protocol](https://agentclientprotocol.com) **Client** role for
Swift, as an `@Observable` container — so a SwiftUI app can drive an ACP agent
over the protocol rather than through a private back door.

Peer to
[FoundationModelsACPAgent](https://github.com/swissarmyhammer/FoundationModelsACPAgent):
one package per ACP role.

- **In-process** — paired in-memory transport to an agent in the same app.
- **Out-of-process** — stdio to any ACP agent, ours or a third party's.

It depends on
[FoundationModelsACP](https://github.com/swissarmyhammer/FoundationModelsACP)
(the wire) and `Observation`, and nothing else. It deliberately does not import
SwiftUI, so it stays usable from AppKit/UIKit and testable headlessly.

> **Status: design only.** No implementation yet — see
> [`plan.md`](plan.md) for the architecture, decisions, and milestones.

## Known limitation: staleness after compaction

The agent's record is not monotonic. Compaction rewrites the agent's
transcript, and entries that a client already showed can stop to exist. The
`session/update` stream is append-only, so a client that only accumulates
updates becomes stale after compaction.

`ACPSessionState` can rebuild its full state from a `session/resume` replay:
call `beginRehydration()`, make the `session/resume` call, and then call
`endRehydration()`. But ACP defines no history-invalidation signal at this
time, so the client cannot know when the agent compacted the record. Until
ACP defines that signal (tracked in `FoundationModelsACP`), staleness after
compaction is a known bug. The host must start a reload itself, for example
each time it opens a session again.
