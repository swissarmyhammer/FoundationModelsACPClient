---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1pp958tnyww127b23wy5pk5
  text: |-
    ### Research

    Read before writing code:

    - `SwiftUIACPClient.connect(over:logger:client:)` is in place
      (`Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift`). The
      factory runs one time, on the main actor, before the connection serves.
    - `SwiftUIACPClient.init(coalescingCadence:clock:)` is public, so `.zero` is a
      plain argument.
    - `ClientSideConnection.updates(for:)` states the rule the card names:
      "Subscribe before driving a turn — updates for a session with no active
      subscriber are dropped."
    - `ScriptedStubAgent` ALREADY answers `newSession` (an earlier task changed it
      from `RequestError.methodNotFound`). What is still missing is the record of
      the `cwd` it received, so only that half of the card's stub change is left.
    - `RepositoryFile.swiftSourceFiles(under:)` is in `SourceFiles.swift`.
    - The wire `ACPLogger` writes only on an anomaly: a happy path logs nothing.
      `NDJSONCodec.decode(line:logger:)` logs `NDJSONCodec: malformed line ...`, so
      a malformed frame written into the agent end of an `InMemoryTransport.pair()`
      is the deterministic way to prove the logger reaches the terminal buffer.
    - `ClientSideConnection.closeSession(_:)` throws, and most agents answer
      `methodNotFound`, which is why the card makes `AgentSession.closeSession(_:)`
      non-throwing.

    Shape chosen for `AgentSession`: an `async init` that stores the container and
    the connection `Self.connect(over:terminal:)` returns, plus the raw `--cwd`
    string. The `--cwd` string stays raw until `openSession()`, because
    `AbsolutePath(rawValue:)` is failable and `openSession()` is the `throws`
    member.
  timestamp: 2026-09-04T17:08:23.450750+00:00
- actor: claude-code
  id: 01m1ppjth8hjmgtt5874wvrt5y
  text: |-
    ### implement — changed

    - evidence: 4 files.
      - NEW `Sources/acp-client/AgentSession.swift` — the seam, plus
        `SessionWorkingDirectoryError`.
      - `Sources/acp-client/AcpClient.swift` — added `static let commandName`, so
        the parser configuration and the name `initialize()` reports to the agent
        come from one constant.
      - NEW `Tests/FoundationModelsACPClientTests/AgentSessionTests.swift` — 10
        tests over `InMemoryTransport.pair()`.
      - `Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift` — records
        the `cwd` of each `session/new` it answered, and exposes
        `lastWorkingDirectory`.
    - `timeout 420 swift test`: 171 tests in 10 suites passed, 0 failures.
      `swift build --build-tests`: 0 warnings.
    - next: `/review`.

    Notes for the next agent:

    - `ScriptedStubAgent` already answered `newSession`; only the `cwd` record was
      missing, so no change to that method's answer was needed.
    - Two acceptance rows are asserted against the SOURCE and not against
      behaviour, each for a stated reason:
      - "spawns nothing" — no run can prove the absence of a spawn, so the test
        scans the file for `AgentProcess`, `Process(`, `posix_spawn` and
        `SubprocessTransport`. Do not name any of those in `AgentSession.swift`,
        comments included, or that test fails.
      - "`.zero` cadence" — the cadence is not readable back off
        `SwiftUIACPClient`, and the only behavioural discriminator against the
        33 ms default is a timing bound too tight to survive a loaded machine.
        The test scans for `coalescingCadence: .zero`. The same file also carries
        a real behavioural test that a streamed chunk reaches the container.
    - The logger test provokes the one diagnostic a happy path never writes: a
      malformed ndJSON line written straight into the far end of the pair, with no
      `AgentSideConnection` on that end.
    - `AgentSession.init` is `async` because connecting is the first of the four
      steps the type shares, and the value IS a live connection. `--cwd` stays a
      raw `String?` until `openSession()`, which is the `throws` member that can
      report a path that is not absolute.
  timestamp: 2026-09-04T17:13:40.136284+00:00
depends_on:
- 01M1MQF486GZVCQNZCMS2KDE0R
- 01M1MPDTZVEP8XEEWQJVP0Y75Z
- 01M1MPCQFQFVAPFCZVVQ95AK7S
position_column: doing
position_ordinal: '80'
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

- [x] `AgentSession` takes a transport and spawns nothing.
- [x] The container is built with a `.zero` coalescing cadence.
- [x] The `Client` the connection serves is the `DecliningClient` wrapper, and
      `session/update` still reaches the container.
- [x] The update subscription is live before `openSession()` returns, so a
      chunk sent immediately after the prompt is not lost.
- [x] `--cwd` reaches `NewSessionRequest.cwd` as an absolute path, and the
      process working directory is unchanged.
- [x] An absent `--cwd` uses the process working directory.

## Tests

- [x] New `Tests/FoundationModelsACPClientTests/AgentSessionTests.swift`,
      driving the seam over `InMemoryTransport.pair()` against a stub agent.
      One test per acceptance row above.
- [x] Extend the unit-suite stub so it **answers** `newSession`:
      `Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift` today
      throws `RequestError.methodNotFound("session/new")`, which this seam
      calls. Give it a session id and record the `cwd` it received.
- [x] One test asserts the recorded `cwd` equals the absolute path that was
      asked for.
- [x] One test asserts the logger wrote to the terminal buffer and not to any
      stdout handle.
- [x] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.