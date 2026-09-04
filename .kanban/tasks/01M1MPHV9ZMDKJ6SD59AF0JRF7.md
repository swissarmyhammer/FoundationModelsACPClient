---
assignees:
- claude-code
depends_on:
- 01M1MPH5DRJ6BEFCX0VBTZVB81
- 01M1MPD4MJ9KMVVQ316YSJPJHK
position_column: todo
position_ordinal: 8d80
title: 'Doctor checks 3 to 5: stdout is only ndJSON, initialize answers in time, and the version matches'
---
## What

`cli-plan.md` §10, rows 3 to 5. All three run over **one** live connection, so
they are one task.

The plan splits check 3 from check 4, and that split does not work. Check 3
says "It writes valid ndJSON, and nothing else, to stdout", but a conformant
ACP agent writes nothing to stdout until it gets a request, so a read that
comes before `initialize` blocks forever against a **correct** agent. The
order is therefore: send `initialize`, then read the answer bytes, then judge
them, with the whole exchange bounded by the doctor's time limit.

3. **stdout carries valid ndJSON and nothing else.** After `initialize` is
   sent, read the first complete line of the agent's stdout and parse it as
   JSON. A line that is not JSON is an `error` whose message quotes the
   offending line. This row is worth the command on its own: a foreign agent
   that prints a banner to stdout fails in a way that looks like a parsing
   defect in **our** client.
4. **`initialize` answers inside the time limit.** Race the call against the
   limit. A limit that ends first is an `error` reporting a timeout, and never
   a hang: the check must return, and the suite must not wait.
5. **The protocol version is one we support.**
   `ClientSideConnection.initialize(_:)` already validates that the agent
   answered with the version that was sent, and throws
   `ProtocolVersionMismatchError` naming both versions. Catch that error and
   turn it into an `error` check whose message holds both versions, so the
   report says "a v1 agent, or a newer draft" in concrete terms.

Read the raw bytes for row 3 through a `FrameTeeTransport` sink, or through a
tee of the agent's stdout, rather than by draining the transport the
connection needs. Whichever route you choose, the connection must still work
afterwards, because rows 4 and 5 use it.

## Acceptance Criteria

- [ ] `bannerOnStdoutAgent` gives an `error` on row 3 that quotes the banner
      line, and the check returns inside the time limit.
- [ ] `silentAgent` gives an `error` on row 4 whose message says the limit was
      reached, and `runHealthChecks()` returns inside that limit.
- [ ] An agent that answers `initialize` with a version other than the one
      sent gives an `error` on row 5 naming both versions.
- [ ] `wellBehavedAgent` gives `ok` on rows 3 to 5, and no read blocks.
- [ ] Rows 3 to 5 are reported as skipped when row 1 or row 2 already failed.
- [ ] No agent process outlives `runHealthChecks()`, in every branch above.

## Tests

- [ ] Extend
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`,
      one test per acceptance row above.
- [ ] Extend `StubAgents` with an agent that answers `initialize` with a wrong
      protocol version.
- [ ] One test bounds the whole `silentAgent` case with a deadline and fails
      when `runHealthChecks()` does not return inside it. One test does the
      same for `wellBehavedAgent`, which is the row that proves check 3 no
      longer blocks against a correct agent.
- [ ] One test asserts the pid of each stub is gone after the run, with
      `kill(pid, 0)`.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.