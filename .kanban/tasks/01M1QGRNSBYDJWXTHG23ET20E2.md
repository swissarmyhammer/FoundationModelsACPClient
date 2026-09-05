---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rva3wkhenf4stdpc3bqjqa
  text: |-
    Research, before the first edit.

    - `AgentCommandDoctor.connectedChecks(of:pid:)` builds its own `FrameTeeTransport` over `agent.transport`. The sink of that tee calls `reading.record(line)` and `answer.record(line)`. The tee copies both directions: the inbound lines with `<< `, and each write with `>> `. So a third call in that sink is the seam the card asks for.
    - `AgentCommandDoctor.init` has three callers: `DoctorCommand.doctor(for:)`, the unit suite `Tests/.../AgentCommandDoctorTests.swift`, and the integration suite `IntegrationTests/.../AgentCommandDoctorTests.swift`. A defaulted `frameSink` parameter keeps all three as they are.
    - `run` and `probe` tee through `RunCommand.sessionTransport(over:frames:terminal:)`, and that tee writes with `TerminalOutput.frame(_:)`. `frame(_:)` writes at every verbosity and in a pipe too, so the doctor can point its sink at the same member.
    - `PlainTextDoctorRenderer.render` draws only the rows: status, name, message and fix. Between two `doctor` runs over one agent, the one difference on stdout is the pid in the process row ("the agent started and stayed, as process N"). So the stdout comparison in the test replaces that pid with a fixed token before it compares the bytes. The stub agent writes its pid with `>` (one pid, overwritten), so the test uses one pid file for each run.
    - The stub agent's `initialize` answer carries `info.name == stubAgentName`, so the inbound frame the test looks for holds "stub-agent".
    - `cli-plan.md` §6.1 lists `--frames` among the inert options of `doctor`, with the reason "needs a seam through the check runner". This card adds that seam, so that row must change with the code. `DoctorCommand.swift` decision 4 states the same thing and changes too.
    - `StreamRulesTests.swift` holds a private `lines(of:)` helper that splits a captured stream. The new doctor test needs the same split, so the helper moves to the shared `Support/` directory and both suites read it from there.
    - The LSP is not installed on this machine, so `get callgraph` gave no edges. The caller list above comes from a grep of `AgentCommandDoctor(`.
  timestamp: 2026-09-05T13:14:46.547763+00:00
- actor: claude-code
  id: 01m1rvfnts2y2qv3f0sj05pkwn
  text: |-
    RED, before the sources changed.

    Command: `swift test --package-path IntegrationTests --filter DoctorCommandTests`. Result: 12 tests in 1 suite, 1 failed with 2 issues.

    - `--frames writes the marked initialize request and answer to standard error` failed at DoctorCommandTests.swift:218 and :222. Both messages read `[]`: "no outbound line carried the initialize request: []" and "no inbound line carried the initialize answer: []". Why: `DoctorCommand` parses `--frames` and gives `AgentCommandDoctor` nothing, and the sink of the doctor's own tee feeds its two readings only. So stderr held zero bytes.
    - `the report on stdout is the same with --frames and without, apart from the pid` passed before the change. It is a guard: it fails only when a teed line reaches stdout, and a flag that does nothing cannot make it fail. It stays because the card asks for it, and because the implementation must not break it.

    New test support: `Support/CapturedStreams.swift` now holds `text(_:)` and `lines(of:)`, moved out of `StreamRulesTests.swift`, so both suites split a captured stream the same way.
  timestamp: 2026-09-05T13:17:48.761945+00:00
- actor: claude-code
  id: 01m1rvpaz5bz72621qb63nc09t
  text: |-
    ### implement — changed

    - evidence: 7 files.
      - `Sources/AcpClientCore/AgentCommandDoctor.swift` — new `frameSink: FrameLineSink?` property and a defaulted `frameSink:` init parameter. The sink of the doctor's own tee now calls `frameSink?(line)` after `reading.record(line)` and `answer.record(line)`, so a caller sees exactly the lines the readings judged. The three existing callers of the init compile as they are.
      - `Sources/AcpClientCore/DoctorCommand.swift` — `run()` builds the doctor with `doctor(for:frameSink:)`. New `frameSink(frames:)` returns `nil` without the flag, and with it a closure over a `TerminalOutput(verbosity: .quiet)` that calls `frame(_:)`, which writes at every verbosity and in a pipe. Decisions 1, 3 and 4 at the head of the file now say that the exchange is the one thing that reaches stderr, and that `--frames` shapes the diagnosis.
      - `Sources/AcpClientCore/FrameTeeTransport.swift` — `typealias FrameLineSink = @Sendable (String) -> Void`, used by the tee's own sink and by the two files above.
      - `cli-plan.md` §6.1 — `--frames` leaves the inert-options row of `doctor`; a paragraph after the table says how the doctor tees it.
      - `IntegrationTests/.../DoctorCommandTests.swift` — two new tests: `--frames writes the marked initialize request and answer to standard error`, and `the report on stdout is the same with --frames and without, apart from the pid`. The second replaces the agent's pid in each report with one token before it compares the bytes, because the process row names the pid and two runs start two agents. A helper reads the pid from a pid file the stub writes.
      - `IntegrationTests/.../Support/CapturedStreams.swift` (new) — `text(_:)` and `lines(of:)`, moved out of `StreamRulesTests.swift` so both suites split a captured stream with one helper.
      - `IntegrationTests/.../StreamRulesTests.swift` — the two private helpers removed.
    - red then green: before the source change, `swift test --package-path IntegrationTests --filter DoctorCommandTests` failed 1 of 12 with 2 issues (stderr held `[]`); after it, 12 of 12 pass. The stdout-comparison test passed both before and after, as the RED comment records.
    - test counts: `swift test` (root) 223 tests in 19 suites passed; `swift test --package-path IntegrationTests` 87 tests in 12 suites passed. Zero failures, zero warnings, zero skipped. No pid file and no agent script is left in the temporary directory.
    - callers after the signature change: `AgentCommandDoctor.init` has a defaulted new parameter, so `DoctorCommand`, the unit `AgentCommandDoctorTests` and the integration `AgentCommandDoctorTests` compile unchanged; `FrameTeeTransport.init` takes the same type under the new alias, so `RunCommand.sessionTransport` and `FrameTeeTransportTests` compile unchanged. Both suites prove it.
    - one note on the byte-for-byte criterion: two `doctor` runs cannot write identical stdout bytes, because row 2 names the pid of the agent each run started. The test therefore compares the bytes after it replaces that one pid with a fixed token, and it requires that the pid was in the report, so the replacement is proven to act.
    - next: `/review`.
  timestamp: 2026-09-05T13:21:27.013442+00:00
- actor: claude-code
  id: 01m1rvtcktt0ypxtmxnkavp2bm
  text: |-
    ### test — green
    - Root: `swift package clean` then `swift build` — build complete, no warnings. `swift test` — 223 tests, 19 suites, all passed, 0 failures, 0 skipped.
    - Nested: `swift package --package-path IntegrationTests clean` then `swift build --package-path IntegrationTests` — build complete, no warnings. `swift test --package-path IntegrationTests` — 87 tests, 12 suites, all passed, 0 failures, 0 skipped.
    - No fix was needed. No file was changed.
  timestamp: 2026-09-05T13:23:39.770827+00:00
position_column: doing
position_ordinal: '80'
title: Wire --frames into doctor, so a diagnosis can show the handshake it ran
---
## What

`cli-plan.md` §6.1 gives `--frames` to every subcommand: "Write every ndJSON
message to stderr, in both directions, with a direction mark." `run` and
`probe` obey it. `doctor` parses the flag and does nothing with it.

The gap is structural, not an oversight of the wiring: `AgentCommandDoctor`
builds its OWN `FrameTeeTransport`, whose sink feeds the two readings rows
three to six rest on, and it hands the connection a silent `TerminalOutput` so
that no check can write on the report a caller is rendering
(`Sources/AcpClientCore/AgentCommandDoctor.swift`, and decision 4 at the head
of `Sources/AcpClientCore/DoctorCommand.swift`).

`--frames` is the reason this binary exists, and the §10 defect it catches best
— an agent that writes a banner to stdout — is exactly the one a person then
wants to SEE on the wire. So the doctor needs a seam that tees each line to
standard error beside its own readings, without letting the tee write into the
report.

## Acceptance Criteria

- [x] `AgentCommandDoctor` takes an optional line sink, and calls it for every
      teed line beside its own two readings.
- [x] `DoctorCommand` passes the tee of `TerminalOutput` when the command line
      carried `--frames`, and nothing otherwise.
- [x] `acp-client doctor --frames -- <agent>` writes the marked messages to
      stderr, and the report on stdout is byte for byte what the same run
      without `--frames` wrote.
- [x] A default `doctor` run still writes nothing to stderr.

## Tests

- [x] An integration test drives `doctor --frames` against the well-behaved
      stub agent and asserts stderr holds the marked `initialize` request and
      answer.
- [x] One test compares the stdout of a `--frames` run with the stdout of a
      plain run over the same agent.