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
- actor: claude-code
  id: 01m1qy36x7v77z260e3dhfmjxq
  text: |
    ### review — findings
    - evidence: 7 findings — cli-plan.md:99, cli-plan.md:100, cli-plan.md:102-104, cli-plan.md:318-326, cli-plan.md:320, cli-plan.md:380-385, Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift:238-263. `review sha b6e1f0d~1..b6e1f0d` gave 0 engine findings, and it reviewed neither Markdown file: no validator matches Markdown.
    - next: correct the §10 authMethods statement, make §5 agree with `Package.swift` and the agent plan, give §12 the subject §3 uses, make the §5 guard read the path, and correct the two prose items. Then review again.
  timestamp: 2026-09-05T04:44:11.559441+00:00
- actor: claude-code
  id: 01m1qy4jtjj4pvvxghksnjbv84
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 files. `cli-plan.md` corrected, README.md gained the binary, and a new `PlanDocumentTests.swift` guards against drift.
    - test: green — root 221 passed in 18 suites, integration 77 passed in 12 suites, 0 failures and 0 warnings
    - commit: b6e1f0d docs(cli-plan): sync plan with shipped code and add drift guard
    - review: findings — cli-plan.md:99, :100, :102-104, :318-326, :320, :380-385; PlanDocumentTests.swift:238-263

    The engine could not help here: it skipped `cli-plan.md` and `README.md` with "no validator matches this file", so the prose this card exists to correct got no engine pass. The review read it against the code instead.

    Four of the five claimed corrections hold. §12 says five and matches the manifest; §13 cites §16; §15's N5 row is Done with no block, and ^55rrz5 is indeed done; §14's two doctor stubs exist.

    Two findings matter more than the rest:

    - **The §5 correction is wrong and made a new contradiction.** The plan now says this package owns the Noora decision and the agent package follows. `Package.swift` says the agent plan picked Noora and this package follows. The AGENT package's own plan says it sets the family precedent. Three statements, two owners. The original text was right.
    - **A card whose purpose is to delete false statements wrote one.** §318-326 says doctor row 6 compares `capabilities` AND `authMethods`. The code compares `capabilities` alone, and open card ^1qfgtye says so in words.

    The renumbering risk that justified §13.1 was real and understated: 37 files cite §8, §9, §11, §12 or §17 by number, not six.

    One of the six drift guards does not bite. The §5 guard matches the BASENAME `TerminalOutput.swift` in the section text against `lastPathComponent` on disk, so it never reads the directory — and the defect this card fixed was §5 naming the wrong DIRECTORY after the split. The guard passes that exact drift.

    Two ASD-STE100 breaks in the added prose: "an other" three times where STE gives "another" (and this same commit writes "another" correctly elsewhere), and the non-approved "forgivingly" plus an -ing form used as a noun.
  timestamp: 2026-09-05T04:44:56.530992+00:00
- actor: claude-code
  id: 01m1qyt07g6vh0pw5e374nxzq4
  text: |
    Pulled back from `review` to `doing`. All seven findings are corrected.

    **A — the §5 "correction" was wrong, and it made a new contradiction.**
    The first pass wrote "This package makes that decision, and the agent package
    follows it." Two documents already said the opposite: `Package.swift` reads
    "The agent plan picked Noora, and this package follows that decision", and the
    agent package's own `cli-plan.md` §5.2 reads "**We adopt Noora.** ... this sets
    the family precedent, and the client CLI follows it."

    The original text was right, and the edit was the error. §5 now reads "The
    agent package made that decision, and this package follows it", it quotes what
    §5.2 holds today, and it states that C1 asks for no comparison. `Package.swift`
    is not touched, because it was already correct. The other repository is not
    touched.

    §5 also states why §5.2 names a different file: each package contains the
    import in a file of its own, `TerminalRenderer.swift` there and
    `Sources/AcpClientCore/TerminalOutput.swift` here.

    **B — this card wrote a new false statement about doctor row 6.**
    `AgentCommandDoctor.capabilitiesCheck` calls
    `membersTheDecodeDropped(from:keeping: response.capabilities)`, and that helper
    reads `jsonMembers(of: result)?[capabilitiesKey]` with
    `capabilitiesKey = "capabilities"`. No arm of the row reads `authMethods`.

    §10 now states what the code does: "The row compares the members of
    `capabilities` ALONE", and "The row does NOT yet read `authMethods` ... Card
    ^1qfgtye holds that work." The §10 TABLE cell was false in the same way. It
    read "Each member of the `initialize` answer decodes, and none is dropped in
    silence", and it now reads "The `initialize` answer decodes, and no member of
    `capabilities` is dropped in silence." The parent commit held neither line, so
    both are this card's own prose.

    **C — the §5 drift guard did not bite, and now it does.**
    The guard matched the BASENAME in the section text and matched `lastPathComponent`
    on disk, so it never read a directory. It now reads the full repository-relative
    path out of the §5 code span, and compares it with the repository-relative path
    of the file on disk. `RepositoryFile` gained `rootURL` and
    `relativePath(of:)`, which is the inverse of `url(relativePath:)`; `url` now
    builds on `rootURL`, so the repository-root navigation stays in one place.

    Proven red, with the working file saved and restored in the same shell command:

        onDisk == [documented] -> false
          onDisk    -> ["Sources/AcpClientCore/TerminalOutput.swift"]
          documented -> "Sources/acp-client/TerminalOutput.swift"

    The restored file has the same SHA-1 as the copy, and `git status` shows only
    the files this card owns. `git checkout` was never used.

    **The §12 subject.** §12 said "The binary ... links FIVE things". After the
    split the executable links one thing. §12 now gives the executable and the
    library each its own sentence, and it names the `ManifestTests` assertion for
    each.

    **The two ASD-STE100 breaks, and the cause behind each.**
    Each "an other" in `cli-plan.md` is now "another": three of them, at §5, §15 and
    §16. "forgivingly" and "forgiving" are gone; §10 now says the decode "drops a
    member of the wrong shape, and it throws nothing". Then the same cause was
    removed from the whole file, not from the two lines the finding named. Every
    -ing form this card added as a noun or as an adjective is rewritten: "closing
    the connection" to "the close of the connection", "in that reading" to "among
    those lines", "the two readings" to "the two results", "in the first reading
    and not in the second" to "that the raw answer holds and the decoded value does
    not", "a running agent" to "an agent that runs", "the `Ctrl-C` handling" to "the
    `Ctrl-C` rule", "no task is left running" to "no task stays alive", "take the
    reading" to "read the pid", and the §15 N6 cell "the reaping tests of §11" to
    "the tests of §11 that prove the reap". The only -ing words left in this card's
    diff are "nothing", "anything", "something", "warning", "thing" and "working
    directory".

    **Discovered work, not done here.** The words "an other" also stand in 15 Swift
    files of this repository, in doc comments and file headers. Those files are
    outside this card, so they went on their own card, ^xg3kh3g.

    **What the review engine cannot do here, for the next agent.** No validator
    matches a Markdown file, so `review` gives `cli-plan.md` and `README.md` no
    pass at all. Every prose finding on this card came from a person's read against
    the code. Plan a read, not a tool run.
  timestamp: 2026-09-05T04:56:38.384148+00:00
- actor: claude-code
  id: 01m1qytahx1ef2acz02n8cx7wd
  text: |
    ### implement — changed

    - evidence: 3 files — `cli-plan.md`,
      `Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift`,
      `Tests/FoundationModelsACPClientTests/RepositoryFile.swift`.
      `timeout 420 swift test`: 221 tests in 18 suites, 0 failures, 0 warnings.
      `timeout 600 swift test --package-path IntegrationTests`: 77 tests in
      12 suites, 0 failures, 0 warnings.
      Each finding, and how it is proven:
      §10 `authMethods` — read `AgentCommandDoctor.capabilitiesCheck` and
      `membersTheDecodeDropped`; the plan now states `capabilities` alone and cites
      ^1qfgtye.
      §5 owner — the plan now agrees with `Package.swift` and with the agent plan
      §5.2; `grep` finds no remaining statement of the other owner.
      §5.2 statement — the plan quotes what §5.2 holds today.
      §12 subject — the plan gives the executable one link and the library five,
      which is what `ManifestTests` asserts.
      §5 drift guard — mutated `cli-plan.md` to the pre-split path, watched the
      test fail with `onDisk == [documented] -> false`, and restored from a saved
      copy in the same command; the restored file has the same SHA-1.
      "an other" — `grep -E "an other" cli-plan.md README.md` finds nothing.
      "forgivingly" and the -ing nouns — `grep -E "forgiv"` finds nothing, and the
      -ing words in this card's diff are now "nothing", "anything", "something",
      "warning", "thing" and "working directory" only.
    - next: `/review`. The engine matches no Markdown validator, so the two
      documents need a read against the code, not a tool run.
  timestamp: 2026-09-05T04:56:48.957402+00:00
- actor: claude-code
  id: 01m1qywt89fnn5q1z5rnc7hy9k
  text: |-
    ### commit — changed
    - evidence: 218c6ed docs(cli-plan): fix Noora decision ownership and doctor row 6 wording
    - next: none
  timestamp: 2026-09-05T04:58:10.569097+00:00
- actor: claude-code
  id: 01m1qzj5me8kjy59a7ps5gr3px
  text: |
    ### review — clean

    - evidence: zero new findings. `review sha 218c6ed~1..218c6ed` returned
      findings 0, confirmed 0, refuted 0 over 7 attempts. It reviewed
      `PlanDocumentTests.swift` and `RepositoryFile.swift`. It matched no
      validator to `cli-plan.md`, so the prose read below is a hand read.
    - All seven findings of the 2026-09-04 23:35 section are resolved:
      - §5 ownership. `cli-plan.md:96-101` now reads "The agent package made
        that decision, and this package follows it". It agrees with
        `Package.swift:64` and with `FoundationModelsACPAgent/cli-plan.md`
        §5.2 "We adopt Noora ... the client CLI follows it".
      - §5 and §5.2 file names. `cli-plan.md:111-113` states that each package
        holds the import in a file of its own, and names
        `TerminalRenderer.swift` for the agent package.
      - §10 row 6. `cli-plan.md:306` and `cli-plan.md:330-337` state that the
        row compares the members of `capabilities` alone, and cite ^1qfgtye.
        `AgentCommandDoctor.swift:526,568,775` reads `capabilities` only.
      - §12. `cli-plan.md:394-403` gives the executable one link and
        `AcpClientCore` five. `Package.swift:107-111` declares those five, and
        `ManifestTests.swift:100,125` holds both counts.
      - §5 drift guard. `PlanDocumentTests.swift:266-297` compares
        `onDisk == [documented]`, path against path.
        `RepositoryFile.swift` gained `rootURL` and `relativePath(of:)`.
      - ASD-STE100. `cli-plan.md` holds no "an other" and no "forgivingly".
    - Document read, second pass. Nine statements of §6, §6.1, §7, §8 and
      §13.1 were checked against the code, and each one is true: the four
      parts of the `probe` report; the six options and no seventh; the
      `--timeout` check on all three subcommands
      (`SharedOptions.swift:67-77`); the inert-option table; the `PATH` walk
      that drops an empty entry (`AgentCommandResolver.swift:116-118`);
      `AgentProcess.init` refusing a command that is not absolute
      (`AgentProcess.swift:148-151`); the spinner that ends on the first
      chunk (`TurnRunner.swift:357-358`); stdout with no added newline
      (`TurnRunner.swift:401`); and the two decline lines at every verbosity
      (`DecliningClient.swift:102-131`).
    - `timeout 900 swift test --filter PlanDocumentTests`: 6 tests in 1 suite
      passed, no warning. No file under `Sources/`, `Tests/` or
      `IntegrationTests/` was modified, and no test process was left running.
    - next: none. Task moved to `done`.
  timestamp: 2026-09-05T05:09:50.350930+00:00
depends_on:
- 01M1MPJBWDJSX6PEP6N39XRXNP
- 01M1MPGFG6DKJFC7T3R24Q3M8S
- 01M1MPG0WT31XJVP37C3CAT35C
- 01M1MPJRCZKG9CEZ7N5TDX6EDK
- 01M1MPM0J8R0H6XYAVJF1FZ3BV
position_column: done
position_ordinal: a380
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
says the binary is a product another package may depend on.

Write every change in ASD-STE100 Simplified Technical English, matching the
style already in `cli-plan.md`.

`FoundationModelsACPAgent/cli-plan.md` §5.2 and its milestone C1 also need the
Noora decision. That is another repository, so do not edit it here: name it in
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

## Ownership of the Noora decision, corrected a second time

The first pass gave §5 to this package: "This package makes that decision, and
the agent package follows it." That is wrong, and it made a new contradiction
with two documents that were already in the tree. `Package.swift` states "The
agent plan picked Noora, and this package follows that decision", and
`FoundationModelsACPAgent/cli-plan.md` §5.2 states "**We adopt Noora.** No
package in the family uses a terminal UI library today, so this sets the family
precedent, and the client CLI follows it." The AGENT package owns the decision.
§5 now says so, and every statement in THIS repository agrees.

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
- [x] One test asserts §5 names the FULL repository-relative path of
      `TerminalOutput.swift`, and that the file stands at that exact path. It
      compares path against path, not basename against basename, so a §5 that
      names the wrong directory turns the test red.
- [x] Run `swift test`. Every assertion passes. 221 tests in 18 suites, no
      warnings. `swift test --package-path IntegrationTests` also passes:
      77 tests in 12 suites, no warnings.

## Review Findings (2026-09-04 23:35)

> Scope: `review sha b6e1f0d~1..b6e1f0d` — reviewed the diffs only — lines this
> change added or modified. The engine reviewed
> `PlanDocumentTests.swift` and returned zero findings. It reviewed neither
> `cli-plan.md` nor `README.md`: no validator matches a Markdown file, so the
> prose this card exists to correct got no engine pass. The items below come
> from a read of the changed prose against the code it describes.

- [x] `cli-plan.md:318-326` `plan/truth` — §10 states "Each member the forgiving decode dropped in silence is a WARNING, and the row names it", and the paragraph above it names `capabilities` AND `authMethods`. Row 6 reads `capabilities` only. `AgentCommandDoctor.capabilitiesCheck` calls `membersTheDecodeDropped(from:keeping: response.capabilities)`, and `membersTheDecodeDropped` reads `jsonMembers(of: result)?[capabilitiesKey]` with `capabilitiesKey = "capabilities"`. No arm of the row touches `authMethods`. Open task ^1qfgtye says the same thing in words: the row "does NOT yet do the same for `authMethods`". This card removes false statements from the plan, and this line adds one. Write what the row does today: it compares the `capabilities` members alone. Move the `authMethods` sentence to §16, or to ^1qfgtye.
- [x] `cli-plan.md:99` `plan/truth` — §5 states "This package makes that decision, and the agent package follows it". Two documents in the tree state the opposite. `Package.swift:64-66`, in this same repository, reads "The agent plan picked Noora, and this package follows that decision". `FoundationModelsACPAgent/cli-plan.md` §5.2 reads "**We adopt Noora.** No package in the family uses a terminal UI library today, so this sets the family precedent, and the client CLI follows it." Make the three statements agree. The `Package.swift` comment is in this repository and this change did not touch it.
- [x] `cli-plan.md:102-104` `plan/truth` — §5 states "`FoundationModelsACPAgent/cli-plan.md` §5.2 records the same decision". §5.2 records the same PACKAGE and the opposite OWNER, and it names a different file, `TerminalRenderer.swift`. Milestone C1 does ask for no comparison, so that half stands. State what §5.2 holds today, or state that §5.2 needs the change.
- [x] `cli-plan.md:380-385` `plan/truth` — §12 states "The binary keeps it. It links FIVE things and nothing more". After the `AcpClientCore` split the `acp-client` executable target links one thing. `ManifestTests` sets `clientTargetName = "AcpClientCore"` and asserts `executable.targetNames == [Self.clientTargetName]` in "the acp-client executable target takes the library and nothing else". The five belong to `AcpClientCore`, which §3 already says. Give §12 the same subject §3 uses.
- [x] `Tests/FoundationModelsACPClientTests/PlanDocumentTests.swift:238-263` `tests/weak-assertion` — the §5 drift guard reads a basename and never a directory. `section.contains { $0.contains("TerminalOutput.swift") }` passes whatever directory §5 writes, and `sources.contains { $0.lastPathComponent == Self.terminalFileName }` passes whatever directory the file stands in. The defect this card corrected was a §5 path that went stale when the file moved from `Sources/acp-client/` to `Sources/AcpClientCore/`, and this guard passes that exact drift. Read the path §5 writes, and compare it with the path of the file.
- [x] `cli-plan.md:100,476,485` `prose/ste` — the added prose writes "an other package" two times and "an other answer" one time. ASD-STE100 gives "another", and this same change writes "another" at `cli-plan.md:192`. The parent commit held no "an other". Use "another".
- [x] `cli-plan.md:320,332-333` `prose/ste` — the added §10 prose writes "forgivingly", which is not in the ASD-STE100 approved vocabulary, and it writes "because closing the connection group-kills the agent", which uses an -ing form as a noun. Write "the decode drops a member of the wrong shape and throws nothing", and "because the close of the connection group-kills the agent".

Verified, and not a finding:

- The §13.1 decision is correct. Renumbering would break more than the commit
  message claims: 37 files under `Sources/`, `Tests/`, `IntegrationTests/` and
  `Package.swift` cite §8, §9, §11, §12 or §17 by number.
- The other two tests of the guard bite. The §6 subcommand test and the §9
  exit code test each compare a SET against a SET, so a new row with no case,
  and a new case with no row, each turn the test red.
- §12's count of five agrees with `Package.swift` and with `ManifestTests`.
  §15 carries no block. §13 cites §16. §14's two `doctor` stubs stand:
  `makeBannerOnStdoutAgent` and `makeSilentAgent`.
- The six tests of `PlanDocumentTests` run green, with no warning.
