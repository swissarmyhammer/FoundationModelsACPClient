---
assignees:
- claude-code
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
- 01M1MPCQFQFVAPFCZVVQ95AK7S
- 01M1MQF486GZVCQNZCMS2KDE0R
position_column: todo
position_ordinal: '8780'
title: Decline every permission request and elicitation, and say so on stderr
---
## What

`acp-client` sends `ACPClient.advertisedCapabilities`, which advertises
elicitation in both modes, so a foreign agent may send
`session/request_permission` or `elicitation/create` in the middle of the one
turn. A headless binary has no person to ask, and `cli-plan.md` gives no
policy. **Decided: decline, and write one stderr line naming what was
refused.** A batch run never grants an agent something a person did not see,
and the behaviour is testable byte for byte.

`ClientSideConnection` serves one `Client`. `SwiftUIACPClient` answers these
two methods by holding the request as pending state until a UI resolves it,
and there is no UI here. So the binary wraps the container, through the new
`connect(over:logger:client:)` overload that the library seam task adds. The
old two-argument `connect` hard-wires the container as the client, so this
task cannot start before that seam exists.

Create `Sources/acp-client/DecliningClient.swift`:

- `@MainActor final class DecliningClient: Client`. It holds the
  `SwiftUIACPClient` and a `TerminalOutput`.
- `sessionUpdate(_:)` and `elicitationComplete(_:)` forward to the container
  unchanged. A wrapper that does not forward leaves the observable state
  empty, and every later task that reads the container breaks.
- `requestPermission(_:)` does **not** forward. It selects the request's
  reject or cancel option and returns that outcome at once. When the request
  offers no such option, it returns the `cancelled` outcome, which is the
  spec's result for a request the user did not decide.
- `createElicitation(_:)` does **not** forward. It returns the decline
  outcome at once, for form mode and for url mode alike. It never opens a URL
  and never carries a credential back over ACP.
- Each refusal writes one line through `TerminalOutput.error(_:)`, so
  `--quiet` still shows it. The line names the method and the subject: for a
  permission request, the tool call or the command; for an elicitation, the
  mode.

This is an exception to §8's "a default run writes nothing to stderr until it
fails". The documentation task adds it to §8.

Read the generated `RequestPermissionResponse` and
`CreateElicitationResponse` outcome unions in `FoundationModelsACP` and use
the exact cases they define; do not invent an outcome shape.

## Acceptance Criteria

- [ ] A `session/request_permission` is answered with a reject or cancel
      outcome, and the call returns without waiting for anything.
- [ ] A request that offers no reject option is answered `cancelled`.
- [ ] An `elicitation/create` in form mode and in url mode is both declined,
      with no URL opened and no credential value sent back.
- [ ] Every `session/update` still reaches the container, so the observable
      state is unchanged by this wrapper.
- [ ] Each refusal writes exactly one stderr line, at `.quiet` too, and writes
      nothing to stdout.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/DecliningClientTests.swift`.
      Build a `DecliningClient` over a real `SwiftUIACPClient` and a
      `TerminalOutput` on a buffer sink, call the four `Client` methods
      directly, and assert the returned values and the buffer contents. No
      process spawn.
- [ ] One test uses options that hold a reject option and asserts that option
      is selected; a second uses options with no reject option and asserts
      `cancelled`.
- [ ] One test drives a stub agent over `InMemoryTransport.pair()` that sends
      an elicitation during a turn, and asserts the turn still reaches its
      stop reason rather than hanging. The stub must **answer** `newSession`:
      `Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift` throws
      `RequestError.methodNotFound("session/new")` today, and the turn path
      calls it.
- [ ] One test asserts a forwarded `session/update` lands in the container's
      session state.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.