---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1qx3nnshsnsqmdndn1vs3te
  text: |-
    Picked up. Research done before any edit.

    **What `cli-plan.md` already carries, and what it still lacks**

    - §3 is ALREADY split into the two tables the executable/library split needs, and the
      library row already lists five links including `FoundationModelsExtras`. The
      acceptance row for §3 is met by the text that stands. What it does NOT say is the
      WORD "five", and §12 still says the binary "links this package, the wire, the parser
      and the terminal package" — FOUR, omitting the family leaf. `ManifestTests` already
      states "cli-plan.md section 12 permits the command-line client five dependencies",
      so §12 is the section that contradicts the code, not §3. §12 is corrected here.
    - §5 already names `Sources/AcpClientCore/TerminalOutput.swift`, which is the real
      path after the target split. The card's "the code is `Sources/acp-client/…`" is
      older than the split. What §5 still says wrongly is "This package follows that
      decision", which the user's own decision reverses.
    - §15 still says "N5 … Blocked by Extras D1 to D3" and "N5 waits for the `Doctorable`
      module in Extras". Both are false twice over: the module is written, AND the
      re-resolve task (^55rrz5) is `done`. Every one of N1 to N6 has its card in `done`.

    **Facts read out of the source, for the prose**

    - `TerminalOutput` builds Noora's `Terminal` with `signalBehavior: .none`; the default
      `.restoreAndExit` installs SIGINT/SIGTERM/SIGQUIT/SIGHUP handlers that print a
      cursor escape to STDOUT and `exit(0)` — breaking §8 and the §11 Ctrl-C alike. It
      also reads `isatty(STDERR_FILENO)` itself, because `Terminal.isInteractive()` reads
      STDIN and `Terminal.isColored()` reads stdout.
    - `TurnRunner.run()` adds the `--timeout` sleeper and the Ctrl-C reader as CHILDREN of
      the same `withThrowingTaskGroup` that holds the prompt, the spinner and the reader.
    - The turn ends on `.stateUpdate(.idle(_))` arriving, not on the prompt answer:
      v2 `PromptResponse` carries only `meta`.
    - `ProbeCommand` waits `commandWait` (2 s), polled every 20 ms, for
      `available_commands_update`, and reports `waitEndedFirst` rather than an empty list.
    - `AgentCommandDoctor` row 3 judges the bytes the `initialize` exchange already
      produced, through the frame tee — reading stdout for a line would wait for ever
      against a conformant agent. Row 6 decodes the RAW `result` and names each member the
      forgiving decode dropped. Row 7 uses `killpg(pid, 0)` and runs BEFORE
      `session.teardown()`.
    - `AgentSession.connect` is where `SwiftUIACPClient` is driven: the container is built
      with a zero coalescing cadence and `connect(over:logger:client:)` serves a
      `DecliningClient` wrapping it. `RunCommand` never names either type.
    - `AgentCommandResolver` walks `PATH` itself because `AgentProcess.init(command:)`
      throws `commandNotAbsolute` for anything not starting with `/`.
    - Inert options: EVERY §6.1 option is inert for `doctor`, and `--timeout` alone is
      inert for `probe`. `SharedOptions.validate()` still rejects a `--timeout` of zero or
      less on all three subcommands, so the value is not wholly ignored.

    **Section numbering**

    The decline policy goes in as §13.1, under "Client capabilities", rather than as a new
    top-level section. Renumbering is not open: `ExitCode.swift`, `AcpClient.swift`,
    `ManifestTests`, `ExitCodeTests`, `TurnRunnerTests`, `ForbiddenImportTests` and a
    dozen more doc comments cite §8, §9, §11, §12 and §17 by number.
  timestamp: 2026-09-05T04:26:58.105390+00:00
- actor: claude-code
  id: 01m1qxgtdmn7q31tkk9zx5vrez
  text: |-
    ### implement — changed

    - evidence: 3 files — `cli-plan.md`, `README.md`, and the new
      `Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift`.
      `timeout 420 swift test`: 221 tests in 18 suites, 0 failures, 0 warnings.
      `timeout 600 swift test --package-path IntegrationTests`: 77 tests in
      12 suites, 0 failures, 0 warnings.
    - next: `/review`.

    **TDD order.** The six tests were written first and run first. Three went RED
    against the plan as it stood: the §13.1 heading did not exist, the §15 N5 row
    read "Blocked by Extras D1 to D3", and `README.md` never named `acp-client`.
    The other three — the §6 subcommand set, the §9 exit-code set, and the §5 file
    name — were GREEN on the first run, because the plan already agreed with the
    code there. Each of those three is a drift guard the card asks for by name, and
    each can still fail: drop a row from either table, or rename the file §5 names,
    and the set comparison goes red.

    **The false assertions corrected.**

    1. **§12 counted four dependencies, not five.** The card blamed §3, but §3 was
       already correct after the target split. §12 read "this package, the wire,
       the parser and the terminal package" and omitted `FoundationModelsExtras`,
       while `ManifestTests` already states "cli-plan.md section 12 permits the
       command-line client five dependencies". §12 now names five and says why the
       family leaf is one of them.
    2. **§5 said this package FOLLOWS the agent package.** The user's decision
       reverses that: the decision is made here, Noora is taken directly, and no
       spike compares it.
    3. **§13 pointed the open question at §15.** §15 is Milestones. It now points
       at §16, which is Open items.
    4. **§15 said N5 waits for Extras.** It waited for two things and both are
       behind it: the `Doctorable` module is written, and ^55rrz5 pushed the Extras
       `main` branch and re-resolved this package. Every one of N1 to N6 has its
       card in `done`, so §15 now carries a State column reading Done for each.
    5. **§14 said the two `doctor` stubs "need" writing.** They are written. §14
       now states where each suite stands and how the unit/integration split is
       structural rather than a flag.
    6. **`SessionWorkingDirectoryError` cannot be thrown from any command line.**
       The plan asserted nothing false about this, because it asserted nothing at
       all. §6.1 now states the fact: the value is made absolute against the process
       working directory and handed to the agent unchecked, so a path that names no
       directory is the agent's to refuse. The DECISION stays open, and §16 now
       carries it — the question belongs to ^x71mrtr, and a person answers it.

    **What else went in, from the decisions the build made.** §4 names the three
    packages Noora adds. §5 names the `signalBehavior: .none` decision and the
    `isatty` on stderr. §6.1 carries the inert-option table and the zero-or-less
    `--timeout` usage error. §7 carries the `PATH` resolution and why the library
    refuses it. §8 carries the `idle` end-of-turn and the decline-line exception.
    §9 carries the two rows of code 0. §10 carries rows 3, 6 and 7. §11 carries the
    task-group children, the real-pid proof, and the sentence that the reap cannot
    be proven from outside the run.

    **One structural decision, recorded so the next reader does not re-open it.**
    The decline policy went in as §13.1 rather than as a new top-level section.
    A new §14 would renumber §14 to §17, and `ExitCode.swift`, `AcpClient.swift`,
    `ManifestTests`, `ExitCodeTests`, `TurnRunnerTests`, `ForbiddenImportTests` and
    a dozen more doc comments cite §8, §9, §11, §12 and §17 by number. Every one of
    them would have gone wrong in silence.

    **Not done here, by the card's own instruction.**
    `FoundationModelsACPAgent/cli-plan.md` §5.2 and its milestone C1 need the same
    Noora decision. That is an other repository. §5 here now states that the agent
    package follows, and the pull request description must name the edit that
    repository still owes.
  timestamp: 2026-09-05T04:34:08.948345+00:00
depends_on:
- 01M1MPJBWDJSX6PEP6N39XRXNP
- 01M1MPGFG6DKJFC7T3R24Q3M8S
- 01M1MPG0WT31XJVP37C3CAT35C
- 01M1MPJRCZKG9CEZ7N5TDX6EDK
- 01M1MPM0J8R0H6XYAVJF1FZ3BV
position_column: doing
position_ordinal: '80'
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

## Path and state corrections made while implementing

The paths and the states in the "What" section above were checked against the
repository, and three of them had moved:

- **§3 was already correct.** The card describes the plan BEFORE the
  executable/library split. §3 already carries two tables, and the library row
  already lists five links including `FoundationModelsExtras`. What did NOT say
  five was **§12**, which read "this package, the wire, the parser and the
  terminal package" — four, omitting the family leaf — while `ManifestTests`
  already states "cli-plan.md section 12 permits the command-line client five
  dependencies". §12 is corrected, and §3 now writes the word "five" as well.
- **The §5 file name was already correct.** After the split the file stands at
  `Sources/AcpClientCore/TerminalOutput.swift`, which is what §5 already named.
  The `Sources/acp-client/…` spelling in the card is older than the split.
- **N5 is not blocked at all.** The card expects one remaining block: the Extras
  `main` push and the re-resolve. That task is ^55rrz5, and it is `done`. Every
  one of N1 to N6 has its card in `done`, so §15 now carries a State column
  reading Done for each.

## Section numbering

The decline policy went in as **§13.1**, under "Client capabilities", rather
than as a new top-level section. Renumbering is not open: `ExitCode.swift`,
`AcpClient.swift`, `ManifestTests`, `ExitCodeTests`, `TurnRunnerTests`,
`ForbiddenImportTests` and a dozen more doc comments cite §8, §9, §11, §12 and
§17 by number.

## Acceptance Criteria

- [x] §3 says five dependencies and names `FoundationModelsExtras`.
      §12 says five as well, which is where the count was wrong.
- [x] §5 states the Noora decision as made, with no reference to a pending
      spike, and names the real file. The macOS 15 CI risk is recorded, and so
      are the two decisions the file makes past Noora's defaults:
      `signalBehavior: .none`, and reading `isatty` on stderr itself.
- [x] `cli-plan.md` holds a section for the decline policy, with its reason.
      §13.1.
- [x] §9 holds a row for an `idle` with no stop reason and a row for
      `StopReason.unknown`.
- [x] §15 no longer says N5 is blocked by Extras D1 to D3.
- [x] §16 names the interactive permission policy as an open item, beside the
      open `--cwd` question of ^x71mrtr.
- [x] `README.md` names `acp-client` and shows two invocations.

## Tests

- [x] New `Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift`,
      built on `RepositoryFile.read(relativePath:)`. It asserts `cli-plan.md`
      holds the decline-policy section heading, that the §15 N5 row does not
      hold the word "Blocked", and that `README.md` names `acp-client`.
- [x] One test asserts every subcommand name that §6 lists is a subcommand
      `AcpClient.configuration` declares, so the document and the parser
      cannot drift.
- [x] One test parses every exit code out of the §9 table and asserts each one
      has a case in `AcpClientExitCode.allCases`, and that no case is missing
      from the table.
- [x] One test asserts §5 names `TerminalOutput.swift` and that the file
      exists, through the shared `swiftSourceFiles(under:)` helper.
- [x] Run `swift test`. Every assertion passes. 221 tests in 18 suites, no
      warnings. `swift test --package-path IntegrationTests` also passes:
      77 tests in 12 suites, no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.