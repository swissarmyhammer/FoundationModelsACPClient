---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1qdteknvnx040w6tfk692h7
  text: |-
    ### Research

    **The paths on the card are stale.** The CLI code moved in ^83zshz: `Sources/acp-client/` now holds a four-line `@main` shim only, and every check lives in `Sources/AcpClientCore/`. The card text is corrected to match.

    What the code says:

    - `Sources/AcpClientCore/AgentCommandDoctor.swift` (from ^btzvb81) holds rows 1 and 2. `Doctorable` uses `doctorName`/`doctorCategory`, `runHealthChecks()` is NON-throwing, and `HealthStatus` has no `skipped` case, so a row that could not run is a `warning`.
    - `Sources/AcpClientCore/AgentSession.swift` is the connect-and-initialize seam. `AgentSession(over:terminal:cwd:)` is `@MainActor`, takes any `ACPTransport`, and starts no process. `initialize()` throws `ProtocolVersionMismatchError`.
    - `ProtocolVersion` is `UInt16` on the wire (`FoundationModelsACP/Core/ProtocolVersion.swift`), and `ProtocolVersionMismatchError` carries `sent` and `received`.
    - `ClientSideConnection.initialize(_:)` compares the answered version with the sent one and throws the mismatch itself, so row 5 catches rather than compares.
    - `Connection.call` wraps its continuation in `withTaskCancellationHandler`, and a cancelled request is failed at once with `CancellationError`. So the time limit of row 4 can cancel the request rather than abandon it, and the check always returns.
    - `NDJSONCodec.frames(from:logger:)` LOGS and SKIPS a line it cannot decode; it does not end the stream. So a banner on stdout does not break the handshake, and rows 4 and 5 still pass for `bannerOnStdoutAgent`. Row 3 is the one row that catches it, which is the point `cli-plan.md` §10 makes about that row.
    - `FrameTeeTransport` copies each whole line to a sink, marked `<< ` inbound and `>> ` outbound, and it calls the sink BEFORE it yields the chunk to the consumer. So a line that reached the connection has already reached the sink, and reading the sink after `initialize()` returned needs no wait.

    **No new dependency.** `ManifestTests` pins `AcpClientCore` at five dependencies; rows 3 to 5 need `Foundation`, `FoundationModelsACP` and `Synchronization`, all of which the target already reaches.
  timestamp: 2026-09-04T23:59:47.317672+00:00
- actor: claude-code
  id: 01m1qe550swk02vampkfewpytm
  text: |-
    ### Implementation landed

    **The card's file paths were stale, and the description is now corrected.** The
    CLI code moved in ^83zshz. Rows 3 to 5 landed in
    `Sources/AcpClientCore/AgentCommandDoctor.swift`, beside rows 1 and 2, and not
    in `Sources/acp-client/`, which now holds a four-line `@main` shim only.

    **Check 3 changed, and the description records the change and its reason.** The
    card asked the row to read the FIRST complete line of stdout. It now judges
    every complete line the tee saw while the `initialize` race of row 4 ran, and
    reports the first OFFENDING one. That terminates against a conformant agent —
    the row waits for nothing, because `FrameTeeTransport` calls its sink before it
    yields a chunk to the connection — and it catches a banner emitted later in the
    exchange as well.

    What the shape looks like:

    - `runHealthChecks()` now builds the report as `[command row] + startedAgentChecks(...)`,
      and `startedAgentChecks` as `[process row] + connectedChecks(over:)`. The
      `defer { agent.shutdown() }` still stands after the `AgentProcess` init
      succeeds, so the connection of rows 3 to 5 runs inside the reap.
    - `checkNamesInOrder` is the ordered row list, and `checksThatDidNotRun(after:)`
      slices it with `drop(while:).dropFirst()`. No index lookup, no optional, and a
      new row later needs one entry.
    - `InitializeOutcome` keeps a version mismatch apart from a failure, because the
      two rows that read it disagree: the agent DID answer, and it answered in time,
      so row 4 passes while row 5 fails.
    - The limit CANCELS the pending `initialize` rather than abandoning it.
      `Connection.call` wraps its continuation in `withTaskCancellationHandler` and
      fails a cancelled request at once, so `await handshake.value` always returns
      and nothing keeps running behind the report. Nothing but the limiter cancels
      that task, so `CancellationError` IS the limit having ended first.
    - `AgentStandardOutputReading` is a `Mutex`-backed `Sendable` class behind the
      tee sink. It drops the outbound direction and the `[incomplete]` tail, and it
      judges a line with `JSONSerialization`, whose default refusal of a top-level
      fragment is exactly the strictness an ACP message needs.
    - The connection behind these rows takes a `TerminalOutput` whose sink discards
      every byte and whose terminal reading is `false`. `cli-plan.md` §8 makes the
      doctor's report its output, so a check may write no line of its own.

    Discoveries worth keeping:

    - `NDJSONCodec.frames(from:logger:)` logs and SKIPS a line it cannot decode, so
      a banner on stdout does not end the handshake. `bannerOnStdoutAgent` therefore
      reports `[ok, ok, error, ok, ok]`, and row 3 is the ONLY row that catches it.
      That is the §10 claim about that row, measured.
    - The silent agent reports `[ok, ok, warning, error, warning]`: it wrote no
      line, so row 3 could not run and row 5 had no answer to read. §9 ranks the
      `error` above both warnings, so the exit code is unchanged.

    `ManifestTests` still passes: rows 3 to 5 needed `Foundation`,
    `FoundationModelsACP` and `Synchronization`, and no new package dependency.
  timestamp: 2026-09-05T00:05:37.945501+00:00
- actor: claude-code
  id: 01m1qe5a1jkc6qc352rk4yh110
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/AcpClientCore/AgentCommandDoctor.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift. `timeout 420 swift test` → 201 tests in 15 suites passed. `timeout 600 swift test --package-path IntegrationTests` → 46 tests in 8 suites passed. Zero failures, zero warnings, zero skipped. Both builds clean. The card's file paths were corrected on the description, and the change to check 3 is recorded there with its reason.
    - next: `/review`
  timestamp: 2026-09-05T00:05:43.090190+00:00
depends_on:
- 01M1MPH5DRJ6BEFCX0VBTZVB81
- 01M1MPD4MJ9KMVVQ316YSJPJHK
position_column: doing
position_ordinal: '80'
title: 'Doctor checks 3 to 5: stdout is only ndJSON, initialize answers in time, and the version matches'
---
## What

`cli-plan.md` §10, rows 3 to 5. All three run over **one** live connection, so
they are one task.

**Path correction.** The card was written before ^83zshz moved the CLI code.
`Sources/acp-client/` now holds a four-line `@main` shim only. Every check in
this card lands in `Sources/AcpClientCore/AgentCommandDoctor.swift`. The paths
below are corrected.

The plan splits check 3 from check 4, and that split does not work. Check 3
says "It writes valid ndJSON, and nothing else, to stdout", but a conformant
ACP agent writes nothing to stdout until it gets a request, so a read that
comes before `initialize` blocks forever against a **correct** agent. The
order is therefore: send `initialize`, then read the answer bytes, then judge
them, with the whole exchange bounded by the doctor's time limit.

3. **stdout carries valid ndJSON and nothing else.** After `initialize` is
   sent, read the agent's stdout and parse each complete line as JSON. A line
   that is not JSON is an `error` whose message quotes the offending line. This
   row is worth the command on its own: a foreign agent that prints a banner to
   stdout fails in a way that looks like a parsing defect in **our** client.
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

## The change to check 3, and its reason

The card's own wording — "read the FIRST complete line of the agent's stdout"
— is the one part that could not be made to work as written, and the plan
review named the hazard. What landed instead:

- The row never READS stdout on its own. `initialize` is sent, the race of row
  4 bounds the wait, and the row then judges every complete line the agent
  wrote while that ran. `FrameTeeTransport` calls its sink BEFORE it yields a
  chunk to the connection, so a line that reached the handshake has already
  reached the reading and the row waits for nothing.
- It reports the FIRST OFFENDING line rather than the first line. That catches
  a banner emitted later in the exchange as well, at no cost, and it is the
  line a person needs quoted.
- A run where the agent wrote no complete line at all — the `silentAgent` case
  — is a row that COULD NOT RUN, reported as a warning naming the initialize
  row. §9 ranks the `error` of row 4 above it, so the exit code is unchanged.

`NDJSONCodec.frames(from:logger:)` logs and SKIPS a line it cannot decode, so a
banner does not end the handshake: `bannerOnStdoutAgent` fails row 3 and passes
rows 4 and 5. That is the point §10 makes about this row.

## Acceptance Criteria

- [x] `bannerOnStdoutAgent` gives an `error` on row 3 that quotes the banner
      line, and the check returns inside the time limit.
- [x] `silentAgent` gives an `error` on row 4 whose message says the limit was
      reached, and `runHealthChecks()` returns inside that limit.
- [x] An agent that answers `initialize` with a version other than the one
      sent gives an `error` on row 5 naming both versions.
- [x] `wellBehavedAgent` gives `ok` on rows 3 to 5, and no read blocks.
- [x] Rows 3 to 5 are reported as skipped when row 1 or row 2 already failed.
      `HealthStatus` states no `skipped`, so each is a `warning` naming the row
      to repair first — the reading ^btzvb81 landed and review accepted.
- [x] No agent process outlives `runHealthChecks()`, in every branch above.

## Tests

- [x] Extend
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`,
      one test per acceptance row above.
- [x] Extend `StubAgents` with an agent that answers `initialize` with a wrong
      protocol version — `makeWrongProtocolVersionAgent(pidFile:)`, answering
      `stubAgentUnsupportedProtocolVersion`.
- [x] One test bounds the whole `silentAgent` case with a deadline and fails
      when `runHealthChecks()` does not return inside it. One test does the
      same for `wellBehavedAgent`, which is the row that proves check 3 no
      longer blocks against a correct agent.
- [x] One test asserts the pid of each stub is gone after the run, with
      `kill(pid, 0)` — through the suite's shared `processExists(_:)`, on the
      passing branch, the timeout branch and the version-mismatch branch.
- [x] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.