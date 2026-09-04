---
assignees:
- claude-code
depends_on:
- 01M1MQG0S4YXS3CKAE34A9AX26
- 01M1MPB4MKQH0Z50EH2DDJHW3G
- 01M1MPC2YVFK0A9NX4T9H4M0EV
- 01M1MPECJSM165NAWX5F3NKX9A
position_column: todo
position_ordinal: 8b80
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

- [ ] `probe` prints the protocol version, the capabilities, the
      authentication methods and the slash commands of a stub agent.
- [ ] `probe` sends no `session/prompt`, checked by a stub that records every
      method it received.
- [ ] `probe` closes the session it opened.
- [ ] An agent that reports no slash command and an agent that never sends
      `available_commands_update` give **different** report text, and both
      exit 0.
- [ ] `--cwd` reaches the `session/new` request.
- [ ] `--json` writes valid JSON to stdout, and the plain form writes no JSON.
- [ ] `probe` exits 0 when the agent answers, and 1 when the spawn or the
      `initialize` fails. The agent pid is gone after both.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/ProbeReportTests.swift`. It
      builds `ProbeReport` values directly and asserts the plain text and the
      JSON for each of the three command states. No process spawn.
- [ ] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/ProbeCommandTests.swift`.
      Extend `StubAgents` with an agent that reports two authentication
      methods and two slash commands and appends every received method name to
      a file, and with one that never sends `available_commands_update`.
      Assert the stdout report holds each value, and assert the file holds no
      `session/prompt` and does hold `session/close`.
- [ ] One test asserts `--json` output parses with `JSONSerialization` and
      holds the four keys.
- [ ] One test asserts `probe` against a command that does not exist exits 1
      with an explanatory stderr line and an empty stdout.
- [ ] Run `swift test` and `swift test --package-path IntegrationTests`. Every
      assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.