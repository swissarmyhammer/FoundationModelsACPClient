---
assignees:
- claude-code
depends_on:
- 01M1MPHV9ZMDKJ6SD59AF0JRF7
- 01M1MPC2YVFK0A9NX4T9H4M0EV
position_column: todo
position_ordinal: '9780'
title: 'Doctor checks 6 and 7: the capabilities read, and the agent leaves nothing behind'
---
## What

`cli-plan.md` §10, the last two rows.

6. **The advertised capabilities are readable.** The plan says a malformed
   `initialize` result gives an error, and **as written the check can never
   fail**. The generated `InitializeResponse.init(from:)` decodes
   `capabilities` with `container.forgivingDecode(..., default:
   AgentCapabilities())` and `authMethods` with
   `forgivingDecodeArrayIfPresent(...)`, so a malformed capability object
   quietly becomes a default value and never throws. Only two fields do throw:
   `info` and `protocolVersion`, both `try container.decode`.

   So restate row 6 against what the wire really enforces: report an `error`
   when the `initialize` answer cannot be decoded at all — a missing or
   mistyped `info` or `protocolVersion` — and report a **warning** when
   `capabilities` came back as the empty default while the raw answer held a
   `capabilities` key, because that means the agent sent a shape this build
   could not read. The documentation task records in §10 that the forgiving
   decoders make a stricter check impossible.

7. **The process ends when its stdin closes, and it leaves no child.** Close
   the agent's stdin, wait a bounded interval, and check the pid with
   `kill(pid, 0)`. An agent that is still running is a **warning**, not an
   error: it is usable, and it leaks. The `fix` text says a leaked agent holds
   gigabytes of model weights. Check the process group too, so an agent that
   died while its own child lives is also caught.

Row 7 is the one row that gives a `warning`, and it is why `cli-plan.md` §9
needs exit code 5 at all.

## Acceptance Criteria

- [ ] An agent whose `initialize` answer omits `protocolVersion` gives an
      `error` on row 6.
- [ ] An agent that sends a `capabilities` object this build cannot read gives
      a `warning` on row 6, and not a silent `ok`.
- [ ] `wellBehavedAgent` gives `ok` on rows 6 and 7.
- [ ] An agent that ignores a closed stdin gives a `warning` on row 7, and the
      report's `worstStatus` is `warning`.
- [ ] An agent that ends but leaves a child gives a `warning` on row 7.
- [ ] No agent process, and no grandchild, outlives `runHealthChecks()`.

## Tests

- [ ] Extend
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`,
      one test per acceptance row above.
- [ ] Extend `StubAgents` with three scripts: one whose `initialize` answer
      omits `protocolVersion`; one that ignores a closed stdin and keeps
      running; and one that spawns a child, writes both pids to a pid file,
      and exits while the child lives. The existing `AgentProcessTests` holds
      the pid-file pattern for the last one.
- [ ] One test asserts the whole report's `worstStatus` is `warning` and its
      `AcpClientExitCode.forDoctorStatus` value is 5, for the leaking-agent
      case.
- [ ] One test asserts the pid and the grandchild pid are both gone after the
      run, with `kill(pid, 0)`.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.