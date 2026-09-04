---
assignees:
- claude-code
depends_on:
- 01M1MPJBWDJSX6PEP6N39XRXNP
- 01M1MPGFG6DKJFC7T3R24Q3M8S
- 01M1MPG0WT31XJVP37C3CAT35C
- 01M1MPJRCZKG9CEZ7N5TDX6EDK
- 01M1MPM0J8R0H6XYAVJF1FZ3BV
position_column: todo
position_ordinal: '9280'
title: Record the CLI decisions in cli-plan.md and README.md
---
## What

Several decisions were made while planning this work, and several statements in
`cli-plan.md` disagree with what the code can do. A plan that disagrees with
the code is worse than no plan. Correct each one.

Edit `cli-plan.md`:

- **§3, the binary table.** It says the binary links four things and omits
  `FoundationModelsExtras`, which contradicts §10: `doctor` uses the Extras
  `Doctorable` module. Say five.
- **§4.** "It costs no new package checkout" is true for ArgumentParser only.
  Noora adds `onevcat/Rainbow`, `apple/swift-log` and `tuist/path`. Say so.
- **§5.** The family takes Noora directly, with no spike. Replace the sentence
  that says this package follows the agent package's C1 result, and say the
  decision is made here and the agent package follows it. Record the risk:
  Noora's own CI runs on macOS 15, so macOS 27 is untested upstream. Correct
  the file name: the plan names
  `Sources/acp-client/Terminal/TerminalRenderer.swift`, and the code is
  `Sources/acp-client/TerminalOutput.swift`. Keep the stderr-only rule and the
  single-import rule.
- **§6.1.** Say that `--cwd` is the **session's** working directory, that it
  applies to `run` and to `probe`, and that the process working directory is
  never changed.
- **New section, permission and elicitation.** `acp-client` advertises
  `ACPClient.advertisedCapabilities`, which advertises elicitation in both
  modes, so a foreign agent may ask. The binary declines every permission
  request and every elicitation, and writes one stderr line for each. Give the
  reason: a headless one-turn binary has no person to ask, and a batch run
  must never grant an agent something a person did not see.
- **§7.** Add that the binary resolves a bare agent command through `PATH`
  itself, because `AgentProcess` accepts an absolute path only.
- **§8.** Add two things. The turn ends on the `idle` `state_update`, and not
  on the prompt acknowledgement, because `PromptResponse` in v2 carries no
  stop reason. And the decline lines are the one exception to "a default run
  writes nothing to stderr until it fails".
- **§9.** Add the two rows the table lacks: an `idle` that carries **no** stop
  reason exits 0, because the schema makes the field optional; and a stop
  reason this build does not know, the generated `StopReason.unknown` case,
  also exits 0.
- **§10.** Restate the capabilities row. The generated
  `InitializeResponse` decodes `capabilities` and `authMethods` forgivingly,
  so a malformed value never throws and a strict check is impossible. Say what
  the check really tests.
- **§15.** N5 is no longer blocked by Extras D1 to D3: that module is written.
  It is blocked until the Extras `main` branch is pushed and this package is
  re-resolved, which is its own task on the board.
- **§16.** Add the interactive permission policy as an open item.

Edit `README.md`: the package is a library landing page today. Add one short
section that names `acp-client`, gives the two example invocations of §6, and
says the binary is a product an other package may depend on.

Write every change in ASD-STE100 Simplified Technical English, matching the
style already in `cli-plan.md`.

`FoundationModelsACPAgent/cli-plan.md` §5.2 and its milestone C1 also need the
Noora decision. That is an other repository, so do not edit it here: name it in
the pull request description instead.

## Acceptance Criteria

- [ ] §3 says five dependencies and names `FoundationModelsExtras`.
- [ ] §5 states the Noora decision as made, with no reference to a pending
      spike, and names the real file.
- [ ] `cli-plan.md` holds a section for the decline policy, with its reason.
- [ ] §9 holds a row for an `idle` with no stop reason and a row for
      `StopReason.unknown`.
- [ ] §15 no longer says N5 is blocked by Extras D1 to D3.
- [ ] §16 names the interactive permission policy as an open item.
- [ ] `README.md` names `acp-client` and shows two invocations.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift`,
      built on `RepositoryFile.read(relativePath:)`. It asserts `cli-plan.md`
      holds the decline-policy section heading, that the §15 N5 row does not
      hold the word "Blocked", and that `README.md` names `acp-client`.
- [ ] One test asserts every subcommand name that §6 lists is a subcommand
      `AcpClient.configuration` declares, so the document and the parser
      cannot drift.
- [ ] One test parses every exit code out of the §9 table and asserts each one
      has a case in `AcpClientExitCode.allCases`, and that no case is missing
      from the table.
- [ ] One test asserts §5 names `TerminalOutput.swift` and that the file
      exists, through the shared `swiftSourceFiles(under:)` helper.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.