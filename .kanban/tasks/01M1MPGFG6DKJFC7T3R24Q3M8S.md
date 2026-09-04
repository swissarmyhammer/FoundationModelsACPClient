---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1q04qk6j1efrstkkpnt5veb
  text: |-
    Picked up. Research done, and one discovery changes the shape of the wait.

    **The update stream cannot detect the arrival of `available_commands_update`.**
    `SessionUpdateRouter.deliver(_:)` drops a notification for a session with no
    active subscriber, and `AgentSession.openSession()` can only subscribe AFTER
    `session/new` answers, because the subscription needs the session id the answer
    carries. The wire reader loop parses the next line as soon as it resumed the
    `newSession` continuation, so an agent that sends its command list right after
    the `session/new` answer reaches the router BEFORE the client subscribes. The
    stream then misses the update every time, not rarely.

    `ClientSideConnection.serveNotification` calls `router.deliver(notification)`
    and THEN `await client.sessionUpdate(notification)`, and the client call has no
    subscriber gate. So the container sees every update, and the container is the
    race-free place to read — which is what the card already says to read.

    **What that needs.** `ACPSessionState` records the command list and nothing
    about its arrival, so an agent that reported an EMPTY list and an agent that
    reported nothing both leave `availableCommands` empty. The card's third state
    ("the wait ended first") cannot be told from the second ("the agent reported
    none") without that fact. So this card adds one observable member to
    `ACPSessionState`: `hasReportedAvailableCommands`. It is session state a
    SwiftUI host wants for the same reason — "no commands" and "not reported yet"
    are different things to draw — and it makes `probe` poll the container rather
    than the stream.

    Other facts for the next reader:

    - `AgentSession.closeSession(_:)` awaits the agent's answer, so every probe stub
      agent MUST answer `session/close`. `probe` is the first caller of it.
    - The stub agents answer with fixed ids 1, 2, 3 in the order the client sends
      its requests. `probe` sends no prompt, so its THIRD request is
      `session/close`, and that answer carries id 3 — the id a run's prompt answer
      carries.
    - `InitializeResponse.authMethods` is `[AuthMethod]?`, and `AuthMethod` is a
      union of `terminal`, `agent` and `unknown`. The stub advertises two `agent`
      methods: 3f30444 pinned the no-terminal-auth decision, and an agent may
      advertise `terminal` only when the client enabled that capability.
    - `AgentCapabilities` is a tree of optional marker structs (auth, session,
      session.additionalDirectories, session.delete, session.mcp{http,stdio},
      session.prompt{audio,embeddedContext,image}). The plain report names the
      advertised paths, because §8 acceptance says the plain form writes no JSON.
  timestamp: 2026-09-04T20:00:44.134438+00:00
- actor: claude-code
  id: 01m1q0tds5wpc40aj2p3m62eqx
  text: |-
    Implementation landed, written test-first: the unit suite failed with "cannot
    find 'ProbeSlashCommands' in scope", and the integration suite failed 27
    assertions against the not-implemented `probe`, before either was made green.

    What each file carries:

    - `Sources/acp-client/ProbeReport.swift` — `ProbeSlashCommands` (the three
      states, with `reported(_:)` as the one place an empty list becomes
      "reportedNone"), and `ProbeReport` with `plainText()` and `jsonText()`. The
      capabilities render as the dotted wire paths of the markers the agent sent
      (`session.prompt.image`), because §8's acceptance says the plain form writes
      no JSON and a path is what a person compares against an agent's own
      documentation.
    - `Sources/acp-client/ProbeCommand.swift` — resolve, spawn, `defer
      { process.shutdown() }`, `RunCommand.sessionTransport(over:frames:terminal:)`
      for the `--frames` tee, initialize, open the session, wait for the command
      list, close the session, one `await session.teardown()` on the single
      following path, then one write to stdout.
    - `Sources/FoundationModelsACPClient/ACPSessionState.swift` —
      `hasReportedAvailableCommands`, set by the update and cleared by the
      rehydration reset. See the comment above for why the card's third command
      state cannot exist without it.

    The report reads like this against a stub that advertises one method and one
    command:

        protocol version: 2
        agent capabilities:
          session
          session.prompt
          session.prompt.image
        authentication methods:
          stub-oauth: Sign in with the stub
        slash commands:
          create_plan: Makes a plan

    Two things the next reader should know:

    - The bounded wait is 2 seconds, and it is a poll of the container rather than
      a read of the update stream. The one test that spends it whole is the agent
      that sends no `available_commands_update`.
    - `swift-format lint` with its DEFAULT configuration reports every file of this
      repository, mine and the pre-existing ones alike, because the default is a
      two-space indent and this repository writes four. It is not the gate; no
      `.swift-format` stands in the tree.

    ### implement — changed
    - evidence: 7 files — Sources/acp-client/ProbeReport.swift (new),
      Sources/acp-client/ProbeCommand.swift,
      Sources/FoundationModelsACPClient/ACPSessionState.swift,
      Tests/FoundationModelsACPClientTests/ProbeReportTests.swift (new),
      Tests/FoundationModelsACPClientTests/SessionStateTests.swift,
      IntegrationTests/.../ProbeCommandTests.swift (new),
      IntegrationTests/.../Support/StubAgents.swift. `swift test` 199 tests in 14
      suites passed; `swift test --package-path IntegrationTests` 34 tests in 6
      suites passed. Every acceptance row and every test row of the card is ticked.
    - next: /review
  timestamp: 2026-09-04T20:12:34.981531+00:00
depends_on:
- 01M1MQG0S4YXS3CKAE34A9AX26
- 01M1MPB4MKQH0Z50EH2DDJHW3G
- 01M1MPC2YVFK0A9NX4T9H4M0EV
- 01M1MPECJSM165NAWX5F3NKX9A
position_column: doing
position_ordinal: '80'
title: 'Implement probe: report what the agent supports, and run no turn'
---
## What

`cli-plan.md` §6. `probe` says **what the agent supports**, and it always exits
0 when the agent answers. It runs no turn.

The report holds four things:

- the protocol version, from `InitializeResponse.protocolVersion`;
- the agent capabilities, from `InitializeResponse.capabilities`;
- the authentication methods, from `InitializeResponse.authMethods`;
- the slash commands.

The slash commands are **not** in `InitializeResponse` and **not** in
`NewSessionResponse`, whose fields are `sessionId`, `configOptions` and
`meta`. In v2 they arrive as an `available_commands_update` session update. So
`probe` opens a session through `AgentSession`, waits a bounded interval for
that update, reads `SwiftUIACPClient.session(for:).availableCommands`, and
closes the session. It sends no prompt. Write that reason as a comment, so a
later reader does not look for a field that does not exist.

**The wait must not lie.** An agent that is slow and an agent that has no
commands both leave the list empty, and a report that shows an empty list for
both is wrong. So `ProbeReport` carries three states for the commands: a list,
"the agent reported none", and "the wait ended first". Report the third as
such, and still exit 0.

`--cwd` applies here too: it is the session's working directory, and `probe`
opens a session. The documentation task adds that to the §6.1 table.

Create `Sources/acp-client/ProbeReport.swift`:

- `struct ProbeReport: Codable, Sendable` holding the four parts, with the
  three-state commands field.
- `func plainText() -> String` — a labelled section per part, and a line that
  says when a part is empty rather than printing nothing.
- The `Codable` conformance is the `--json` form.

Edit `Sources/acp-client/ProbeCommand.swift`: resolve the command, spawn, run
the `AgentSession` handshake, open and close the session, build the report,
and write it to **stdout**. §8 makes `probe` an exception to the stdout rule,
because its report is its output. `--json` writes the JSON form. Exit 0
whenever the agent answered; a spawn or protocol failure exits 1. Tear the
agent down on every path.

## Acceptance Criteria

- [x] `probe` prints the protocol version, the capabilities, the
      authentication methods and the slash commands of a stub agent.
- [x] `probe` sends no `session/prompt`, checked by a stub that records every
      method it received.
- [x] `probe` closes the session it opened.
- [x] An agent that reports no slash command and an agent that never sends
      `available_commands_update` give **different** report text, and both
      exit 0.
- [x] `--cwd` reaches the `session/new` request.
- [x] `--json` writes valid JSON to stdout, and the plain form writes no JSON.
- [x] `probe` exits 0 when the agent answers, and 1 when the spawn or the
      `initialize` fails. The agent pid is gone after both.

## Tests

- [x] New `Tests/FoundationModelsACPClientTests/ProbeReportTests.swift`. It
      builds `ProbeReport` values directly and asserts the plain text and the
      JSON for each of the three command states. No process spawn.
- [x] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/ProbeCommandTests.swift`.
      Extend `StubAgents` with an agent that reports two authentication
      methods and two slash commands and appends every received method name to
      a file, and with one that never sends `available_commands_update`.
      Assert the stdout report holds each value, and assert the file holds no
      `session/prompt` and does hold `session/close`.
- [x] One test asserts `--json` output parses with `JSONSerialization` and
      holds the four keys.
- [x] One test asserts `probe` against a command that does not exist exits 1
      with an explanatory stderr line and an empty stdout.
- [x] Run `swift test` and `swift test --package-path IntegrationTests`. Every
      assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.