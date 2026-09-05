---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1qez1ff827jdhsshw7kfv7r
  text: |-
    ### Research

    **Path correction.** The card's `Sources/acp-client/` paths are stale. The CLI code is in
    `Sources/AcpClientCore/`. `AgentCommandDoctor.swift` is at
    `Sources/AcpClientCore/AgentCommandDoctor.swift`. I corrected the paths as I worked.

    **Rows 1 to 5 confirmed.** `Doctorable` gives `doctorName` and `doctorCategory`;
    `runHealthChecks()` is non-throwing; a row that could not run is a `warning`;
    `defer { agent.shutdown() }` stands from the moment `AgentProcess` is built; the frame tee
    records every complete line before the chunk reaches the connection.

    **Row 6, the hazard, and what the row became.** The card is right that `capabilities` and
    `authMethods` decode forgivingly. I read the generated code to be sure:

    - `InitializeResponse.init(from:)` — `info` and `protocolVersion` are `try container.decode`;
      `capabilities` is `container.forgivingDecode(..., default: AgentCapabilities())`;
      `authMethods` is `forgivingDecodeArrayIfPresent`.
    - `AgentCapabilities.init(from:)` is strict only about the value being a JSON OBJECT. Its
      `auth`, `session` and `_meta` members each go through `forgivingDecodeIfPresent`, so a
      malformed member silently becomes `nil` — that is, "the agent does not support it".

    So a stricter DECODE cannot catch a malformed capability member: the type itself throws
    nothing. The row reads the RAW `initialize` answer line off the frame tee instead, and it
    reports:

    - `error` when the raw `result` does not decode as `InitializeResponse` at all — a missing
      or mistyped `info` or `protocolVersion`.
    - `warning` when the decode succeeded but a member the agent SENT did not survive it. The
      test is a round trip: re-encode the decoded `capabilities` and name every key the raw
      object carried with a non-null value that the re-encoding does not carry. That catches
      `{"session": "yes"}` (dropped to `nil`, so the client believes the agent has no session
      surface), it catches a `capabilities` value that is not an object at all, and it catches a
      member of a newer schema this build cannot read. It does NOT false-warn on `{}`, and it
      needs no hard-coded list of member names, so it cannot rot against the schema.
    - `ok` otherwise.

    The card's literal wording — warn when `capabilities` came back as the empty default while
    the raw answer held a `capabilities` key — would warn on a legal empty `{}`. The round trip
    is the same intent without that false positive. Recorded here as the change and its reason.

    **Row 6 needs a fourth stub.** The card lists three new scripts, but its own acceptance
    criteria need a stub that sends a `capabilities` object this build cannot read. I added it.

    **Row 7 and the stdin close.** `AgentProcess` had NO way to close the agent's stdin without
    killing it: `shutdown()` runs `killpg` then a blocking `waitpid`, and closing the transport
    runs the same teardown through `continuation.onTermination`. So row 7 needs a new
    `AgentProcess.closeStandardInput()`. That is an enabling change in
    `Sources/FoundationModelsACPClient/AgentProcess.swift`, and it is the only change outside
    `Sources/AcpClientCore/`.

    **Row 7 runs BEFORE `session.teardown()`.** Closing the connection cancels the tee's
    forwarding task, which terminates the `AgentProcess` byte stream, which runs
    `terminateCurrent()` and group-kills the agent. So a row 7 placed after the teardown would
    report `ok` against every agent — the same defect the plan review found in row 6.

    **Row 7 tests the process GROUP, not the pid.** `kill(pid, 0)` cannot tell a running agent
    from an unreaped zombie, and an agent that leaves a child holds its own stdout open through
    that child, so the reader thread never reaches EOF and never reaps it. `killpg(pid, 0)`
    answers the question the row actually asks — "did the agent leave anything behind" — for all
    three cases at once: still running, zombie beside a live child, and gone.
  timestamp: 2026-09-05T00:19:46.287804+00:00
- actor: claude-code
  id: 01m1qfp8mk062akxda7bthzc71
  text: |-
    ### implement — changed

    - evidence: 4 files changed.
      `Sources/AcpClientCore/AgentCommandDoctor.swift` (rows 6 and 7, the raw
      answer reading, the process-group watch, and rules 4 to 6 at the head of the
      file), `Sources/FoundationModelsACPClient/AgentProcess.swift` (the new
      `closeStandardInput()` and the optional stdin descriptor behind it),
      `IntegrationTests/.../Support/StubAgents.swift` (four new stub agents, the
      two new `initialize` answers, and `recordedAgentPids(in:)`),
      `IntegrationTests/.../AgentCommandDoctorTests.swift` (four new tests, and the
      seven-row status arrays every earlier test now compares).

      `swift test` — 201 tests in 15 suites, passed.
      `swift test --package-path IntegrationTests` — 50 tests in 8 suites, passed.
      `pgrep -fl "sleep 300"` after both runs — nothing.

      What check 6 became, and why: it reads the RAW `initialize` answer off the
      frame tee, and never the decoded value. `InitializeResponse` decodes
      `capabilities` and `authMethods` forgivingly, so a row that read the decoded
      value would report `ok` against every agent, and the plan review is right
      that such a row is not a check. The row now reports an `error` when the raw
      `result` does not decode as `InitializeResponse` at all — only `info` and
      `protocolVersion` can cause that — and a `warning` when the decode SUCCEEDED
      and dropped a member the agent sent, found by re-encoding the decoded
      `capabilities` and naming every non-null key the raw object carried that the
      re-encoding does not.

    - **The proof that rows 6 and 7 can fail.** I did not have a clean red for the
      new tests, so I earned one by mutation: I replaced the two new rows in
      `connectedChecks` with unconditional `passed(...)` findings and ran the
      suite. Five tests failed with ten assertions — both capabilities tests, both
      teardown tests, and the silent-agent row that expects a did-not-run warning
      on row 6. Then I reverted the mutation and both suites went green again. A
      row that always passes does not survive these tests.

    - **The enabling change outside `AcpClientCore`.** `AgentProcess` had no way to
      close the agent's stdin without killing it, so row 7 could not ask an agent
      to end on its own terms. `AgentProcess.closeStandardInput()` is new, and the
      stdin descriptor inside `AgentProcessState.Live` is now optional so the close
      and the teardown never double-close it. `ManifestTests` still passes: no new
      package dependency, and `AcpClientCore` still declares exactly five.
      `AgentCommandDoctor.swift` now also imports `Darwin` for `killpg`, which is a
      system module and not a package dependency.

    - **A trap worth recording for the next agent.** Row 7 MUST run before
      `session.teardown()`. Closing the connection cancels the frame tee's
      forwarding task, which ends the `AgentProcess` byte stream, which runs
      `terminateCurrent()` and group-kills the agent. A teardown row placed after
      the connection closes would report `ok` against every agent — exactly the
      defect the plan review found in row 6. Rule 5 at the head of
      `AgentCommandDoctor.swift` records this.

    - **Discovered work, filed as ^1qfgtye.** `authMethods` decodes through
      `forgivingDecodeArrayIfPresent`, which drops each malformed ELEMENT and keeps
      the rest. An agent that advertises three authentication methods, one
      unreadable, silently gives the client two, and the person who tries the third
      is told it does not exist. Row 6 already holds the raw array it would need to
      catch that, and it does not compare the counts yet.

    - next: `/review`.
  timestamp: 2026-09-05T00:32:27.283964+00:00
depends_on:
- 01M1MPHV9ZMDKJ6SD59AF0JRF7
- 01M1MPC2YVFK0A9NX4T9H4M0EV
position_column: doing
position_ordinal: '80'
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

   So the row reads the RAW `initialize` answer off the frame tee, and never
   the decoded value. It reports an `error` when that answer cannot be decoded
   at all — a missing or mistyped `info` or `protocolVersion` — and a
   **warning** when the decode SUCCEEDED but dropped a member the agent sent.

   **Change from the wording above, and why.** The warning arm was written as
   "`capabilities` came back as the empty default while the raw answer held a
   `capabilities` key". That rule warns on a legal empty `{}`, which the schema
   allows and which means the agent advertises nothing. The row does a ROUND
   TRIP instead: it re-encodes the decoded `capabilities` and names every key
   the raw object carried with a non-null value that the re-encoding does not
   carry. That is the same intent without the false positive, it also catches a
   `capabilities` value that is not an object at all, and it keeps no list of
   member names of its own to go stale against the schema.
   `AgentCapabilities.init(from:)` reads `auth`, `session` and `_meta` through
   `forgivingDecodeIfPresent`, so a stricter DECODE could not have caught a
   malformed member either. The documentation task records in §10 that the
   forgiving decoders make a stricter check impossible.

7. **The process ends when its stdin closes, and it leaves no child.** Close
   the agent's stdin, wait a bounded interval, and check whether the agent left
   anything behind. An agent that is still running is a **warning**, not an
   error: it is usable, and it leaks. The `fix` text says a leaked agent holds
   gigabytes of model weights. Check the process group too, so an agent that
   died while its own child lives is also caught.

   **Change from the wording above, and why.** The row watches the process
   GROUP with `killpg(pid, 0)` and never the pid with `kill(pid, 0)`. A
   `kill(pid, 0)` cannot tell a running agent from an unreaped zombie of one,
   and an agent that leaves a child holds its own stdout open through that
   child, so `AgentProcess` never reaps it. One `killpg` answers for all three
   cases at once: the agent still running, a zombie beside a live child, and a
   group that emptied.

Row 7 is the one row that gives a `warning`, and it is why `cli-plan.md` §9
needs exit code 5 at all.

## Paths

The description named `cli-plan.md` §10 and the integration test file, and both
were already right. No `Sources/acp-client/` path appears in it. The CLI code
lives in `Sources/AcpClientCore/`, and `AgentCommandDoctor.swift` is at
`Sources/AcpClientCore/AgentCommandDoctor.swift`.

## Acceptance Criteria

- [x] An agent whose `initialize` answer omits `protocolVersion` gives an
      `error` on row 6.
- [x] An agent that sends a `capabilities` object this build cannot read gives
      a `warning` on row 6, and not a silent `ok`.
- [x] `wellBehavedAgent` gives `ok` on rows 6 and 7.
- [x] An agent that ignores a closed stdin gives a `warning` on row 7, and the
      report's `worstStatus` is `warning`.
- [x] An agent that ends but leaves a child gives a `warning` on row 7.
- [x] No agent process, and no grandchild, outlives `runHealthChecks()`.

## Tests

- [x] Extend
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`,
      one test per acceptance row above.
- [x] Extend `StubAgents` with three scripts: one whose `initialize` answer
      omits `protocolVersion`; one that ignores a closed stdin and keeps
      running; and one that spawns a child, writes both pids to a pid file,
      and exits while the child lives. The existing `AgentProcessTests` holds
      the pid-file pattern for the last one.
- [x] A FOURTH script, which the acceptance criteria need and this list did
      not name: `makeUnreadableCapabilitiesAgent(pidFile:)`, which answers
      `initialize` with `"capabilities": {"session": "yes"}`.
- [x] One test asserts the whole report's `worstStatus` is `warning` and its
      `AcpClientExitCode.forDoctorStatus` value is 5, for the leaking-agent
      case.
- [x] One test asserts the pid and the grandchild pid are both gone after the
      run, with `kill(pid, 0)`.
- [x] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.