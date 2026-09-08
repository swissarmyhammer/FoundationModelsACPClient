---
position_column: todo
position_ordinal: '80'
title: 'N3+N4: --frames and probe'
---
## What

Milestones **N3** and **N4** of this repository's `cli-plan.md`.

Asked for by `FoundationModelsACPAgent`, card `^p39z3bc`.

**N3 — `--frames`.** Write every ndJSON message to stderr, in both
directions, with a direction mark. This is the reason the binary
exists: it shows the protocol exchange, so a person can see what an
agent sent. stdout stays the answer text alone.

**N4 — `probe`.** Start the agent, initialize, and print what it
reports: the protocol version, the agent capabilities, the
authentication methods, and the slash commands. Run no turn. Its report
**is** its output, so it goes to stdout. `--json` prints the same report
as JSON. It exits 0 whenever the agent answers — the verdict belongs to
`doctor`, not here.

- [ ] `--frames`, on stderr, both directions
- [ ] `probe`, and its `--json` form
- [ ] `probe` runs no turn

## Acceptance Criteria

- [ ] `--frames` writes the messages to stderr, and stdout stays clean.
- [ ] `probe` prints the stub agent's protocol version, capabilities,
      authentication methods and slash commands.
- [ ] `probe` sends no `session/prompt`.
- [ ] `probe --json` decodes to the same values as the human form.
- [ ] `probe` exits 0 for any agent that answers `initialize`.

## Tests

- [ ] `--frames` against the stub agent: the captured stderr holds both
      directions, and the captured stdout holds only the answer.
- [ ] `probe` against the stub agent: the report names each field, and
      the recording client shows no `session/prompt` was sent.
- [ ] `probe --json` decodes and equals the human form's values.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.