# Writing a client model extension

Serve the `_` extension methods and notifications of an agent, and keep
observable state for each connection.

## Overview

ACP lets an agent send methods and notifications whose names start with `_`.
A host serves them with a ``ClientModelExtension``. The extension registers
its handlers for each connection, and keeps its own state for each
connection. The extension has no name of a vendor: the host names its own
methods.

### Write the extension

An extension is a `Sendable` type. It declares the type of its connection
state, makes a new state for each connection, and registers its handlers:

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

    @MainActor func makeConnectionState() -> ConnectionState {
        ConnectionState()
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
  ``ClientModelExtension/didInitialize(_:state:)`` and
  ``ClientModelExtension/didClose(state:)``.
- The handlers are not main-actor isolated. A handler that changes the
  connection state hops to the main actor with `MainActor.run`.
- A notification handler runs in the read loop of the connection, in arrival
  order. It must return promptly. A request handler runs in its own task, so
  it can wait.
- When the handlers must change the state off the main actor, use a
  `Sendable` class with a `Mutex` as the connection state.
- ``ClientModelExtension/didInitialize(_:state:)`` and
  ``ClientModelExtension/didClose(state:)`` are optional. The defaults do
  nothing.

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
