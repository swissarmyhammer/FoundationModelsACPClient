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
// The prompt is mail: the answer comes when the agent accepts the message.
_ = try await session.prompt([.text(TextContent(text: "Hello"))])

// The reply comes later as session updates, into observable state that a
// view can bind to:
let transcript = session.transcript
let state = session.agentState
```

Each item of `transcript` is a `TranscriptEntry` with a stable `id`, so a
SwiftUI `ForEach` can key on it. A streamed chunk changes only the object of
its own entry, so a view redraws only that row.

For an agent in the same process, `InProcessAgent.makeConnection(serving:)`
connects a new `ConnectionModel` to it over the real ACP wire. The helper
makes an `InMemoryTransport.pair()`, serves your `Agent` on the agent end, and
returns the model, connected and not initialized:

```swift
let model = await InProcessAgent.makeConnection { connection in
    MyAgent(connection: connection)
}
```

`model.disconnect()` ends the input of the agent side, as it ends an agent
process. When the agent closes its side first, the state of the model becomes
`.disconnected`.

## Sub-agent sessions

An agent can start sub-agents. ACP v2 (the Subagent Sessions draft) shows each
sub-agent as a child session. The model is parent and child all the way down:
every session is a `SessionModel`, and each rule below holds at each level.
Depth is not a case.

```swift
let root = try await model.newSession(request)

// The agent announces a child with a `subagent_update`. The model makes the
// child, and adds it to the children of its parent, in announce order.
for child in root.children {
    print(child.displayTitle, child.workState, child.needsAttention)
}
```

**The tree.**

- `parent` is the session that announced this session. It is `nil` for a root
  session. `children` are the sessions that this session announced.
- A child is not in `ConnectionModel.openSessions` or in `sessions` (the list
  of `session/list`). You reach it through its parent.
- `title`, `description`, `cwd`, `additionalDirectories` and `capabilities`
  come from the announcement. An omitted field is unchanged, `null` clears
  it, and a value replaces it. `capabilities` replace as a whole.
- Updates and requests (permission, elicitation) that name a child go to the
  child model, and stay attributed to it.
- The client allows on a child only what its `capabilities` advertise. Today
  that is `cancel()`. `prompt`, set config option, close, resume and delete
  throw `SubagentSessionError.notPermitted` with no request. A child offers no
  slash commands.
- Closing a parent closes and removes its children. A child is also removed
  when the `agents` tool call that started it reaches a final status
  (`completed`, `failed` or `cancelled`). The link is `_meta.sah.agentRun`:
  `startedByToolCallId` on the child, and `ToolCallEntry.childSession` on the
  tool call. A closed model has `isClosed == true`.
  A child with no `agentRun` link is not removed by a tool call: it stays until
  its parent closes. After a resume with no `replayFrom`, a child that the agent
  does not announce again stays with an unknown state, unless its linked tool
  call is already final in the retained transcript: then the model removes it.

**Views for a breadcrumb bar.** These values are computed, so each view gets
the same answer, and each one is `Observable`:

- `ancestors`: the chain from the root to the parent, root first.
- `siblingsIncludingSelf`: the choices of one crumb, in announce order. For a root session,
  they are the root sessions of the connection.
- `descendants`: all sessions below, depth first, in announce order.
- `SessionPathEntry`: one small `Hashable` value for each of these: `sessionId`,
  `title`, `path` (the titles from the root), `workState`,
  `pendingRequestCount` and `needsAttention`. `pathEntry` is this session as
  one entry, and `displayTitle` is its title (the child title, else the
  session title, else the session id).
- `needsAttention`: true when this session or any descendant is
  `requires_action` or has a pending request. A question deep in the tree
  shows on each ancestor.
- Which session a window shows is view state. `ConnectionModel` has no
  selected session.
- Queries for a view: `root`, `path` (the sessions from the root to this
  session), `session(withId:)` (a session of this tree), and
  `nearestOpenAncestor` (the fallback for a removed child).
- `status` tells why a state is what it is: `.running`, `.requiresAction`,
  `.idle`, `.unconfirmed` (a child waits for its first current snapshot),
  `.restoreFailed(reason:)` or `.unknown`. `SessionPathEntry` also carries
  `isConfirmed` and `restoreFailure`.
- `ownNeedsAttention` is true when this session itself waits (a request or
  `requires_action`). `firstWaitingSession` names the first session of the
  tree that waits itself. `branchPendingRequestCount` counts the pending
  requests of the whole branch.
- `canPrompt` (only an open root session) and `canCancel` (a root session, or
  a confirmed child whose capabilities advertise the cancel) tell the
  controls of a view.
- `replayEndCount` changes at the end of each resume, so a view can observe it.
- `ToolCallEntry.childSession` is observable: a view of the agents call sees
  the link arrive and go.
- `children` never holds a closed session: a removed child leaves it at once.

**Resume.** `resumeSession` with `replayFrom` replays the history of the whole
tree before the response.

- The model drops the child models of the session before the replay, and
  rebuilds them from the replayed announcements. A resume with no `replayFrom`
  keeps the child models.
- A snapshot before the response is history only in a resume WITH
  `replayFrom`. In a resume with no `replayFrom`, a snapshot before the
  response is current. History sets the description of the child, and it
  confirms nothing. The response ends the replay of every
  model.
- After the response, a child is **unconfirmed**: `isWorkStateConfirmed` is
  false, `workState` is `.unknown`, it has no capabilities, and `cancel()` is
  refused, until its first current snapshot. A live `state_update` of the
  child does not confirm it. A current snapshot that omits `state` gives an
  unknown state: history never shows as current.
- Replayed content raises no `needsAttention`.
- A failed resume of an open session gives back its transcript, its state and
  its child models: the model keeps the old state aside until the response.

**A child that failed to restore.** The agent announces it with the state
`unknown` and a reason in `_meta.sah.restoreFailure`. The model keeps it in
the tree: `restoreFailure` holds the reason, `workState` is `.unknown`, and it
allows no prompt and no cancel. A later current snapshot with a known state
clears `restoreFailure`. A child that only has no current snapshot is
unconfirmed, and has no `restoreFailure`: the model invents no failure.

**One ordered consumer.** `ConnectionModel` runs one consumer of the ordered
event stream of the connection (`subscribeToAllSessions()` of the wire). It
applies each event to the model of its session in wire order, so the model of
a child always exists before its events and before a request that names it.
A request handler reads the highest event sequence first, and waits until
the consumer applied it. The resume marker is read one time, and it ends the
replay of every model at that position.

## Previews

A SwiftUI `#Preview` or a test of your app can make a populated model with
no agent and no connection. Each transcript item goes through the same merge
engine as a live update, so the preview shows the real state. A preview never
opens a process or a socket.

```swift
#Preview {
    TranscriptView(session: .preview(transcript: [
        .user("Why does the build fail?"),
        .agent("Parser.swift does not import Foundation."),
        .toolCall(title: "Run swift test", kind: .execute, status: .completed),
    ]))
}
```

`SessionModel.previewSample` and `ConnectionModel.previewSample` give ready
models. `prompt(_:meta:)` on a preview model adds the user message and gets
an answer from `PreviewSessionRequestSender`, so its `sendState` changes as
it does in a live model.

`apply(_:)` gives one `SessionUpdate` to a model with no wire, on the same
path as an update of the agent. `PreviewSessionRequestSender.sent` records
each message that the model sends, in send order: prompts, cancels, config
changes, and the answers to permission requests and elicitations. A test can
thus check what a Send button sent:

```swift
let sender = PreviewSessionRequestSender()
let session = SessionModel.preview(requestSender: sender)
let prompt: [ContentBlock] = [.text(TextContent(text: "Fix the test."))]
_ = try await session.prompt(prompt)
#expect(sender.sent == [.prompt(PromptRequest(prompt: prompt, sessionId: session.sessionId))])
```

`SessionModel.preview(pendingPermissions:pendingElicitations:)` makes pending
requests. Each one is in `pendingRequests`, in the given order, and the
elicitations come after the permission requests. An answer records
`.permissionResponse(id:response:)` or `.elicitationResponse(id:response:)`
in `sent`, and returns at once. `ConnectionModel.preview` takes
`pendingElicitations` too: each one is a request-scoped elicitation in
`connection.pendingElicitations`. Give a `PreviewSessionRequestSender` as its
`recorder` to read the answers:

```swift
let recorder = PreviewSessionRequestSender()
let connection = ConnectionModel.preview(pendingElicitations: [signIn], recorder: recorder)
let pending = connection.pendingElicitations[0]
connection.declineElicitation(pending.id)
#expect(recorder.sent == [.elicitationResponse(id: pending.id, response: .object(["action": .string("decline")]))])
```

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
- **A prompt is mail, and the model adds no turn rule.** The agent answers
  `session/prompt` when it accepts the message, and a second prompt while
  one is open is also accepted. `running` and `idle` follow the work of the
  agent, and an `idle` can have no stop reason. After `cancel(meta:)`, the
  idle with the `cancelled` stop reason can come later. `agentState` keeps
  the last state that the agent sent, and the transcript keeps each update.
- **One consumer applies the events of all sessions.** The updates of
  different sessions have no order between their own streams. The connection
  model reads the one ordered stream, so a child, a request for it, and the end
  of a replay always meet in wire order.
- **Token-rate chunks are coalesced.** A `SessionModel` applies the chunks
  at a display rate, so a SwiftUI view does not redraw for each token. A
  test measures this.
- **The package that spawns an agent owns its process.** `AgentProcess`
  spawns the agent in its own process group, ends the group on shutdown,
  and reaps it. The reap waits for the exit event of the agent, up to a
  time limit, so a teardown always returns. It gives no guarantee under
  `SIGKILL`.

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
