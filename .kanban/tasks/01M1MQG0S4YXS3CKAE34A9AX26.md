---
assignees:
- claude-code
depends_on:
- 01M1MQF486GZVCQNZCMS2KDE0R
- 01M1MPDTZVEP8XEEWQJVP0Y75Z
- 01M1MPCQFQFVAPFCZVVQ95AK7S
position_column: todo
position_ordinal: '9580'
title: Build the shared connect-and-initialize seam that run, probe and doctor use
---
## What

`run`, `probe` and `doctor` all do the same four things before they diverge:
connect over a transport, run `initialize`, open a session, and give back the
session's update stream. Write that one time, and make it take an injected
transport so a unit test drives it over `InMemoryTransport.pair()` with no
process spawn.

Create `Sources/acp-client/AgentSession.swift`:

- `@MainActor struct AgentSession`. It is built from an `any ACPTransport`, a
  `TerminalOutput`, and an optional `--cwd` path. It never spawns a process:
  the caller owns the `AgentProcess`, so a test can hand it an in-memory pair
  and `RunCommand` can hand it the agent's stdio.
- `static func connect(over:terminal:) async -> (SwiftUIACPClient, ClientSideConnection)`.
  It builds the container with `coalescingCadence: .zero`, because §8 wants
  each chunk written as it arrives, and connects through the new
  `connect(over:logger:client:)` overload with a `DecliningClient` wrapper.
  The `ACPLogger` goes to `TerminalOutput.event(_:)`, never to stdout.
- `func initialize() async throws -> InitializeResponse`, sending
  `ACPClient.supportedProtocolVersion` and
  `ACPClient.advertisedCapabilities`.
- `func openSession() async throws -> (SessionId, AsyncStream<SessionUpdate>)`.
  It calls `connection.updates(for:)` **before** it returns, because the wire
  package drops updates for a session with no active subscriber. `--cwd`
  becomes the `NewSessionRequest.cwd` value, made absolute against the process
  working directory; the process working directory itself never changes.
- `func closeSession(_:) async` and a teardown that the caller runs on every
  exit path.

`--cwd` is the **session's** working directory, not this binary's. Write that
as a comment, and note that `probe` uses it too.

## Acceptance Criteria

- [ ] `AgentSession` takes a transport and spawns nothing.
- [ ] The container is built with a `.zero` coalescing cadence.
- [ ] The `Client` the connection serves is the `DecliningClient` wrapper, and
      `session/update` still reaches the container.
- [ ] The update subscription is live before `openSession()` returns, so a
      chunk sent immediately after the prompt is not lost.
- [ ] `--cwd` reaches `NewSessionRequest.cwd` as an absolute path, and the
      process working directory is unchanged.
- [ ] An absent `--cwd` uses the process working directory.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/AgentSessionTests.swift`,
      driving the seam over `InMemoryTransport.pair()` against a stub agent.
      One test per acceptance row above.
- [ ] Extend the unit-suite stub so it **answers** `newSession`:
      `Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift` today
      throws `RequestError.methodNotFound("session/new")`, which this seam
      calls. Give it a session id and record the `cwd` it received.
- [ ] One test asserts the recorded `cwd` equals the absolute path that was
      asked for.
- [ ] One test asserts the logger wrote to the terminal buffer and not to any
      stdout handle.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.