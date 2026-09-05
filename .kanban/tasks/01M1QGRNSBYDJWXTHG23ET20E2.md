---
assignees:
- claude-code
position_column: todo
position_ordinal: 9a80
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

- [ ] `AgentCommandDoctor` takes an optional line sink, and calls it for every
      teed line beside its own two readings.
- [ ] `DoctorCommand` passes the tee of `TerminalOutput` when the command line
      carried `--frames`, and nothing otherwise.
- [ ] `acp-client doctor --frames -- <agent>` writes the marked messages to
      stderr, and the report on stdout is byte for byte what the same run
      without `--frames` wrote.
- [ ] A default `doctor` run still writes nothing to stderr.

## Tests

- [ ] An integration test drives `doctor --frames` against the well-behaved
      stub agent and asserts stderr holds the marked `initialize` request and
      answer.
- [ ] One test compares the stdout of a `--frames` run with the stdout of a
      plain run over the same agent.