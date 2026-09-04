---
assignees:
- claude-code
depends_on:
- 01M1MQHBX56XTYHFZR6K0E160T
- 01M1MPD4MJ9KMVVQ316YSJPJHK
position_column: todo
position_ordinal: 8a80
title: Wire --frames into run, and prove the two streams end to end
---
## What

`cli-plan.md` §6.1 and §8. The unit tests drive the turn logic over an
in-memory pair; this task runs the real binary against a real agent process and
asserts the two file descriptors byte for byte. It is the only way to prove
§8, because §8 is a claim about file descriptors — and it is the only test
that catches a Noora default writing to stdout.

Edit `Sources/acp-client/RunCommand.swift`: when `--frames` is given, wrap the
`AgentProcess` transport in `FrameTeeTransport` before handing it to
`AgentSession`, with the tee's sink pointed at stderr. `--frames` is
independent of `--quiet` and `--verbose`: it is a debugging switch, not a
verbosity level, and it writes its lines whether or not stderr is a terminal.

Add
`IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/StreamRulesTests.swift`,
built on the `CLITestSupport` and `StubAgents` helpers.

## Acceptance Criteria

- [ ] With `wellBehavedAgent`, `acp-client run "hi" -- <agent>` writes only
      the answer text to stdout, byte for byte, with no trailing newline.
- [ ] With stderr captured as a pipe, a default run writes zero bytes to
      stderr.
- [ ] `--quiet` writes zero bytes to stderr and leaves stdout unchanged.
- [ ] `--verbose` writes session event lines to stderr and leaves stdout
      unchanged, byte for byte.
- [ ] `--frames` writes the ndJSON messages to stderr in both directions, and
      stdout stays exactly the answer text.
- [ ] A stub that asks for permission during the turn causes exactly one
      stderr line, and leaves stdout unchanged. This is the §8 exception the
      decline policy creates.
- [ ] The arguments after `--` reach the agent unchanged, flags included.

## Tests

- [ ] `StreamRulesTests.swift`, one test per acceptance row above, each using
      `runAcpClient(_:standardInput:)` and asserting on `Data`, not `String`.
- [ ] One test extends `wellBehavedAgent` to write its own `argv` into a file,
      and asserts the file holds the arguments given after `--`, in order.
- [ ] One test asserts the answer text is identical with stdout a pipe and
      with stdout a file, which pins §8's "no rule that changes with a
      terminal".
- [ ] Extend `StubAgents` with an agent that sends a
      `session/request_permission` mid-turn and then finishes the turn, for
      the decline row.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.