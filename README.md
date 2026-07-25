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
