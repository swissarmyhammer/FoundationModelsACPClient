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

## The `acp-client` binary

The package also ships `acp-client`, a command-line client for any ACP v2
agent. It starts the agent, runs one turn, prints the answer, and exits. With
`--frames` it shows every ndJSON message in both directions, so you can see
what an agent sent.

```
acp-client run "write a haiku" -- acp-agent acp
acp-client probe -- npx @some-vendor/their-acp-agent --model small
```

`acp-client` is an executable **product**, so another package can depend on
this one and spawn the binary from its own tests. The plan it is written
against is [`cli-plan.md`](cli-plan.md).

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
compaction. `ConnectionModel.resumeSession(_:)` with `replayFrom: .start`
rebuilds the transcript of a `SessionModel` from the replay of the agent: the
model clears its transcript at the start of the replay, so the replayed text
does not double. ACP gives no signal when the agent compacts the record.
Until ACP defines that signal (tracked in
[FoundationModelsACP](https://github.com/swissarmyhammer/FoundationModelsACP)),
the host must start a reload itself, for example each time it opens a
session again.
