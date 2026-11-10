# Writing a client model extension

Serve the `_` extension methods and notifications of an agent, keep
observable state for each connection and for each session, and take the
session updates that the extension knows.

## Overview

ACP lets an agent send methods and notifications whose names start with `_`.
A host serves them with a ``ClientModelExtension``. The extension registers
its handlers for each connection, and keeps its own state for each
connection and for each session. The extension has no name of a vendor: the
host names its own methods.

### Write the extension

An extension is a `Sendable` type. It declares the type of its connection
state and of its session state, makes a new state for each connection and for
each session, and registers its handlers:

```swift
import FoundationModelsACP
import FoundationModelsACPClient
import Observation

struct Status: Codable, Sendable {
    let text: String
}

struct StatusExtension: ClientModelExtension {
    @MainActor @Observable
    final class ConnectionState {
        var lastStatus: String?
    }

    @MainActor @Observable
    final class SessionState {
        var isBusy = false
    }

    @MainActor func makeConnectionState() -> ConnectionState {
        ConnectionState()
    }

    @MainActor func makeSessionState(for sessionId: SessionId) -> SessionState {
        SessionState()
    }

    func registerHandlers(
        into handlers: inout ClientModelExtensionHandlers,
        context: ClientModelExtensionContext<Self>
    ) {
        handlers.registerNotification("_vendor/status", params: Status.self) { status in
            await MainActor.run { context.connectionState.lastStatus = status.text }
        }
        handlers.registerMethod("_vendor/echo", params: Status.self) { status in
            status
        }
    }

    @MainActor func didInitialize(_ response: InitializeResponse, state: ConnectionState) {
        state.lastStatus = nil
    }
}
```

Obey these rules:

- The protocol is not main-actor isolated. Write `@MainActor` on
  ``ClientModelExtension/makeConnectionState()``,
  ``ClientModelExtension/makeSessionState(for:)``,
  ``ClientModelExtension/didInitialize(_:state:)``,
  ``ClientModelExtension/didClose(state:)``,
  ``ClientModelExtension/apply(_:to:)`` and
  ``ClientModelExtension/didStartSession(state:mcpServers:)``.
- The handlers are not main-actor isolated. A handler that changes the
  connection state hops to the main actor with `MainActor.run`.
- A notification handler runs in the read loop of the connection, in arrival
  order. It must return promptly. A request handler runs in its own task, so
  it can wait.
- When the handlers must change the state off the main actor, use a
  `Sendable` class with a `Mutex` as the connection state.
- ``ClientModelExtension/didInitialize(_:state:)``,
  ``ClientModelExtension/didClose(state:)``,
  ``ClientModelExtension/apply(_:to:)`` and
  ``ClientModelExtension/didStartSession(state:mcpServers:)`` are optional.
  The defaults do nothing, and the default of
  ``ClientModelExtension/apply(_:to:)`` takes no update.

### Add the extension

Add each extension before the connect. The connection reads the handlers one
time, when it opens:

```swift
let model = ConnectionModel()
model.addExtension(StatusExtension())
let connection = await model.connect(over: transport)
_ = try await model.initialize(request)
let status = model.extensionState(StatusExtension.self)?.lastStatus
```

``ConnectionModel/addExtension(_:)`` while a connection is open has no effect
on that connection, and the model logs one diagnostic. The extension takes
effect at the next connect.

Each connect makes a new connection state for each extension. Thus
``ConnectionModel/extensionState(_:)`` gives a new state after each connect.
The model keeps one extension for each type.

The extensions register their handlers in the order of
``ConnectionModel/addExtension(_:)``. When two extensions register the same
method or notification, the later one wins, and the model logs one
diagnostic.

### Take the session updates

The `session/update` notifications of the agent do not go to the handlers.
The ``SessionModel`` of the session gives each update to
``ClientModelExtension/apply(_:to:)`` of each extension, on the main actor,
before its own rules. The extension gives `true` when it takes the update:

```swift
extension StatusExtension {
    @MainActor func apply(_ update: SessionUpdate, to state: SessionState) -> Bool {
        guard case .unknown("_vendor/busy", .object(let members)) = update,
            case .bool(let isBusy)? = members["busy"]
        else { return false }
        state.isBusy = isBusy
        return true
    }
}
```

Obey these rules:

- The extension sees each update, also each standard update, in arrival
  order. A buffered chunk comes after each update that arrived before it.
- The extensions get the update in the order of
  ``ConnectionModel/addExtension(_:)``. The first extension that gives `true`
  takes the update. A later extension does not get it, and the model adds no
  transcript entry for it.
- An update that no extension takes goes to the rules of the model, as with
  no extension. An `_` update that the model does not know becomes an
  ``UnknownEntry``.
- A standard update that an extension takes changes no other state of the
  model. Give `false` for a standard update that the extension only reads.

### Keep state for each session

Each ``SessionModel`` that the connection makes, also the model of a child
session, makes a new session state for each extension with
``ClientModelExtension/makeSessionState(for:)``. The host reads it with
``SessionModel/extensionState(_:)``:

```swift
let session = try await model.newSession(request)
let isBusy = session.extensionState(StatusExtension.self)?.isBusy
```

These rules decide the life of a session state:

- ``ClientModelExtension/didStartSession(state:mcpServers:)`` gets the
  `session/new` request after the agent accepted it, and the
  `session/resume` request before it goes out. The extension can seed its
  state from the request. A child session gets no call.
- A `session/resume` with a replay of the retained history makes a new
  session state, because the replay gives each update of the session again.
  A failed replay puts the earlier state object back.
- A `session/resume` with no replay keeps the session state. The close of the
  session keeps it too.

A notification handler of a session notification that is not a
`session/update` finds the session on the main actor with
``ClientModelExtensionContext/session(for:)`` or
``ClientModelExtensionContext/sessionState(for:)``:

```swift
handlers.registerNotification("_vendor/session_busy", params: SessionBusy.self) { note in
    await MainActor.run { context.sessionState(for: note.sessionId)?.isBusy = note.busy }
}
```

The context finds only the sessions of its own connection. After the close,
and after a later connect, it finds no session.

### Preview the session state

``SessionModel/preview(sessionId:cwd:transcript:availableCommands:configOptions:mcpServers:pendingPermissions:pendingElicitations:requestSender:extensions:)``
takes the extensions of the session. Each transcript item goes to the
extensions as a live update does, so an `_` update item sets sample data:

```swift
#Preview {
    StatusView(session: .preview(
        transcript: [.update(.unknown("_vendor/busy", .object(["busy": .bool(true)])))],
        extensions: [StatusExtension()]
    ))
}
```

### Wrap the router

A host that puts its own `Client` in front of the router of the model must
give the `extensionHandlers` of the router as its own:

```swift
struct HostClient: Client {
    let router: any Client

    var extensionHandlers: ExtensionHandlers {
        router.extensionHandlers
    }

    // Forward each other call to `router`.
}
```

A wrapper that does not forward them gives no message to an extension.
