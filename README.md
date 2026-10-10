# FoundationModelsACPClient

[![CI](https://github.com/swissarmyhammer/FoundationModelsACPClient/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsACPClient/actions/workflows/ci.yml)

The [Agent Client Protocol](https://agentclientprotocol.com) **Client** role
for Swift, as `@Observable` models. Your app connects to an ACP agent — in
the same process, or an external process over stdio — and its views bind to
the models that the agent's update stream fills. The package depends only on
[FoundationModelsACP](https://github.com/swissarmyhammer/FoundationModelsACP)
(the wire) and Observation. It does not import SwiftUI, so AppKit, UIKit,
and headless tests can use it too.

There are two models. A `ConnectionModel` holds one connection to an agent:
its state, the capabilities of the agent, the auth state, and the open
sessions. A `SessionModel` holds one session: its transcript, its pending
permission requests and elicitations, and the last value of each session
state.

```swift
import FoundationModelsACP
import FoundationModelsACPClient

let model = ConnectionModel()

// Spawn an ACP agent, and connect over its stdio.
let agent = try AgentProcess(command: "/usr/local/bin/my-acp-agent")
_ = await model.connect(over: agent.transport)

_ = try await model.initialize(InitializeRequest(
    info: Implementation(name: "my-app", version: "1.0.0"),
    protocolVersion: ACPClient.supportedProtocolVersion,
    capabilities: ACPClient.advertisedCapabilities
))
let session = try await model.newSession(
    NewSessionRequest(cwd: AbsolutePath(rawValue: "/Users/me/project")))
_ = try await session.prompt([.text(TextContent(text: "Hello"))])

// The streamed reply lands in observable state a view can bind to:
let transcript = session.transcript
```

Each item of `transcript` is a `TranscriptEntry` with a stable `id`, so a
SwiftUI `ForEach` can key on it. A streamed chunk changes only the object of
its own entry, so a view redraws only that row.

For an agent in the same process, make a transport pair with
`InMemoryTransport.pair()` and connect over the client end.

## Install

Add the package to the dependencies in your `Package.swift`:

```swift
.package(
    url: "git@github.com:swissarmyhammer/FoundationModelsACPClient.git",
    branch: "main"
)
```

## Design decisions

- **A client, not *our* client.** The library depends on the ACP wire,
  Observation, the family leaf `FoundationModelsExtras`, and the tracing,
  logging and metrics APIs. It does not depend on `FoundationModelsRouter`,
  `FoundationModelsACPAgent`, `FoundationModelsMCP` or the
  `FoundationModels` framework. A client that knows only ACP can drive any
  conforming agent. If the package needs a type from the agent runtime, the
  ACP interface is incomplete, and the fix goes upstream into ACP.
- **No `import SwiftUI`.** Observation is sufficient for a SwiftUI binding,
  and without a view framework AppKit and a headless test can use the models.
- **`@MainActor` models.** SwiftUI binds state on the main actor, and the
  updates arrive on background tasks. The models do that change of actor
  at one boundary.
- **A projection, never a record.** The transcript of the agent is the
  record. The models can rebuild their state from `session/resume` with
  `replayFrom: .start`, and they are not durable history.
- **ACP v2 only.** v2 is a draft, so this package changes when the schema
  changes.
- **Display terminals are rendered, never driven.** v2 removed the client
  `terminal/*` methods and `fs/*` methods. The agent owns its terminals and
  its file access, and gets the files of the client through MCP. This
  package shows the display terminals of the agent, and it never runs a
  command or touches a file.
- **Token-rate chunks are coalesced.** A `SessionModel` applies the chunks
  at a display rate, so a SwiftUI view does not redraw for each token. A
  test measures this.
- **The package that spawns an agent owns its process.** `AgentProcess`
  spawns the agent in its own process group, ends the group on shutdown,
  and reaps it. It gives no guarantee under `SIGKILL`.

The peer package for the ACP **Agent** role is
[FoundationModelsACPAgent](https://github.com/swissarmyhammer/FoundationModelsACPAgent).

## Known limitation: staleness after compaction

Compaction rewrites the agent's record, but the `session/update` stream only
appends. A client that only collects updates thus becomes stale after
compaction. `ConnectionModel.resumeSession(_:)` with `replayFrom: .start`
rebuilds the transcript of a `SessionModel` from the replay of the agent: the
model clears its transcript at the start of the replay, so the replayed text
does not double. ACP gives no signal when the agent compacts the record.
Until ACP defines that signal (tracked in
[FoundationModelsACP](https://github.com/swissarmyhammer/FoundationModelsACP)),
the host must start a reload itself, for example each time it opens a
session again.
