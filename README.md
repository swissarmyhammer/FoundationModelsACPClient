# FoundationModelsACPClient

[![CI](https://github.com/swissarmyhammer/FoundationModelsACPClient/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsACPClient/actions/workflows/ci.yml)

The [Agent Client Protocol](https://agentclientprotocol.com) **Client** role
for Swift, as an `@Observable` container. Your app connects to an ACP agent —
in the same process, or an external process over stdio — and its views bind
to the session state that the agent's update stream fills. The package
depends only on
[FoundationModelsACP](https://github.com/swissarmyhammer/FoundationModelsACP)
(the wire) and Observation. It does not import SwiftUI, so AppKit, UIKit,
and headless tests can use it too.

```swift
import FoundationModelsACP
import FoundationModelsACPClient

let client = SwiftUIACPClient()

// Spawn an ACP agent, and connect over its stdio.
let agent = try AgentProcess(command: "/usr/local/bin/my-acp-agent")
let connection = await client.connect(over: agent.transport)

_ = try await connection.initialize(InitializeRequest(
    info: Implementation(name: "my-app", version: "1.0.0"),
    protocolVersion: ACPClient.supportedProtocolVersion,
    capabilities: ACPClient.advertisedCapabilities
))
let session = try await connection.newSession(
    NewSessionRequest(cwd: AbsolutePath(rawValue: "/Users/me/project")!))
_ = try await connection.prompt(PromptRequest(
    prompt: [.text(TextContent(text: "Hello"))],
    sessionId: session.sessionId))

// The streamed reply lands in observable state a view can bind to:
let entries = client.session(for: session.sessionId).entries
```

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

## Documentation

The architecture, the decisions, and the milestones are in
[`plan.md`](plan.md). The peer package for the ACP **Agent** role is
[FoundationModelsACPAgent](https://github.com/swissarmyhammer/FoundationModelsACPAgent).

## Known limitation: staleness after compaction

Compaction rewrites the agent's record, but the `session/update` stream only
appends. A client that only collects updates thus becomes stale after
compaction. `ACPSessionState` can rebuild its full state from a
`session/resume` replay (`beginRehydration()`, the `session/resume` call,
then `endRehydration()`), but ACP gives no signal when the agent compacts
the record. Until ACP defines that signal (tracked in
[FoundationModelsACP](https://github.com/swissarmyhammer/FoundationModelsACP)),
the host must start a reload itself, for example each time it opens a
session again.
