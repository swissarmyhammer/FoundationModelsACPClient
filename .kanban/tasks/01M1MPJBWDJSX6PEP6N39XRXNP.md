---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1qgc977h6pes0wad1113dq5
  text: |-
    Picked up. Research done.

    **Path correction.** The card says `Sources/acp-client/DoctorCommand.swift`. That path is stale: commit "Split acp-client into a library target and a thin executable" (^01M1Q5ZSJXM50HEWDVXW83ZSHZ) moved every subcommand into `Sources/AcpClientCore/`. The file to edit is `Sources/AcpClientCore/DoctorCommand.swift`. `Sources/acp-client/` now holds the `@main` type alone. The test path in the card is correct.

    **What is already in place.**
    - `AgentCommandDoctor` is a full `Doctorable` over all seven §10 rows. `runHealthChecks()` is non-throwing and always answers seven rows in a fixed order.
    - `AcpClientExitCode.forDoctorStatus(_:)` maps ok/warning/error to 0/5/1.
    - Extras gives `DoctorRunner(components:).run() -> DoctorReport`, `DoctorReport.worstStatus`, `DoctorReport.jsonData(prettyPrinted:)` (it encodes `checks` alone), and `PlainTextDoctorRenderer.write(_:to:)`, which reads `isatty` of the destination itself and colors only a terminal. That is the "useColor true only when stdout is a terminal" rule the card states, written in the library once.

    **Two decisions this card must make, and what decides them.**

    1. `--timeout` does NOT become the doctor's row limit. Rule 2 at the head of `AgentCommandDoctor.swift` is a recorded decision: "The time limit here is the doctor's own. It is never the `--timeout` of §6.1: that option bounds the TURN a person asked for, and this one bounds a diagnosis." `doctor` runs no turn. So `DoctorCommand` builds the doctor with `AgentCommandDoctor.defaultTimeLimit` and nothing from the command line reaches `timeLimit`. That is also the strongest answer to the review note on ^btzvb81: `min(settleInterval, timeLimit)` cannot collapse to zero, because no caller-supplied number reaches it at all. A test drives `doctor --timeout 0` against a well-behaved agent and asserts exit 0 with every row `ok` — a collapsed limit would fail the settle row or the initialize row.

    2. The silent-agent row needs a longer run bound than `runAcpClient` has today. The doctor's own default limit is 10 s, which is exactly `TransportTestDeadline.limit`, so a `doctor -- <silentAgent>` run takes about 11 s and the shared runner would kill it and throw. `runAcpClient` gains a `within limit: Duration = TransportTestDeadline.limit` parameter, and the doctor suite passes a bound well over the doctor's own limit. The run still fails as a hang if it never returns.
  timestamp: 2026-09-05T00:44:28.775870+00:00
- actor: claude-code
  id: 01m1qgtsj1kp880rxcr26hj86f
  text: |-
    Implementation landed, both suites green.

    **What went in.**
    - `Sources/AcpClientCore/DoctorCommand.swift` — the body replaces the `SubcommandNotImplementedError` throw: one `AgentCommandDoctor` through `DoctorRunner`, the report to stdout (plain through `PlainTextDoctorRenderer.write(_:to:)`, which colors only a terminal; `--json` writes `jsonData()` and one newline, so a script reads one ndJSON record), and the exit code from `AcpClientExitCode.forDoctorStatus(_:)`. The call site carries the reason code 5 exists, so nobody "simplifies" it back to `DoctorReport.exitCode`.
    - `Sources/AcpClientCore/SubcommandNotImplementedError.swift` — DELETED. `doctor` was the last thrower, and its own documentation says "Each milestone deletes its own throw". An unmarked type with no caller is dead code.
    - `IntegrationTests/.../DoctorCommandTests.swift` — new, 10 tests.
    - `IntegrationTests/.../Support/CLITestSupport.swift` — `runAcpClient` gained `within limit: Duration = TransportTestDeadline.limit`. The doctor suite needs it: the doctor's own default limit is ten seconds, which is the shared bound exactly, so the silent-agent run (about 11 s) was killed as a hang under the old fixed bound. Every other caller is unchanged.

    **The `--timeout` hazard the review of ^btzvb81 named.** `--timeout` never reaches `AgentCommandDoctor`. Rule 2 at the head of that file already decided this: the option bounds the TURN, and a doctor runs none. `DoctorCommand` builds the doctor with the type's own default, so `min(settleInterval, timeLimit)` cannot collapse — no number off the command line reaches it. The test drives both `--timeout 0` and `--timeout=-1` against the well-behaved agent and asserts exit 0 with every `--json` entry `ok`; a collapsed limit would fail the settle row or the initialize row. Both spellings were checked to parse: the RED run showed each reaching the subcommand body rather than the usage error.

    **Discovered work, filed rather than done.** `--frames` is parsed by `doctor` and shapes nothing, because `AgentCommandDoctor` builds its own `FrameTeeTransport` and its own silent terminal, and it has no seam for a second sink. §6.1 gives the flag to every subcommand and §10's own worst defect is the one a person then wants to see on the wire, so this is a real gap: ^3et20e2. Decision 4 at the head of `DoctorCommand.swift` records what each §6.1 option shapes for a diagnosis, so the group does not read as an oversight.

    ### implement — changed
    - evidence: 4 files — `Sources/AcpClientCore/DoctorCommand.swift`, `Sources/AcpClientCore/SubcommandNotImplementedError.swift` (deleted), `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/DoctorCommandTests.swift` (new), `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/CLITestSupport.swift`. `timeout 420 swift test`: 201 tests in 15 suites passed. `timeout 600 swift test --package-path IntegrationTests`: 60 tests in 9 suites passed, 10 of them new. Both builds carry zero warnings. Watched every new test fail first: the RED run reported 23 issues over 10 tests.
    - next: `/review`
  timestamp: 2026-09-05T00:52:24.257012+00:00
- actor: claude-code
  id: 01m1qh9hgrds6pacnt5stsdqaz
  text: |
    ### review — clean
    - evidence: `review sha 58883fe~1..58883fe`. counts: findings 0, confirmed 0, refuted 0, attempted 7, failed 0. Zero findings. Task moved to `done`.
    - Five `code-hygiene` tool rules declined one item each on `Sources/AcpClientCore/SubcommandNotImplementedError.swift`, because this change deletes that file. A deleted file has nothing to read; the decline is expected and is not a gap.
    - Judgement asked for, and answered by direct measurement of the built binary:
      1. `--timeout` not reaching the doctor is correct. Its own help text says "End the run if the turn does not stop in time", and `doctor` runs no turn, so the option is out of scope by its own contract. A message saying the option does nothing would have to go to stderr, which §8 and decision 1 of `DoctorCommand.swift` keep empty for this subcommand. `--frames`, `--verbose` and `--cwd` are equally inert here; all four were measured inert, so `--timeout` is not a special case.
      2. `SubcommandNotImplementedError` has no Swift reference left anywhere in `Sources/`, `Tests/` or `IntegrationTests/`. The only remaining mentions are in `.kanban` history. `doctor` was its last thrower.
      3. `runAcpClient(within:)` defaults to `TransportTestDeadline.limit`, the same 10 seconds the call used before. No other caller's behaviour changed. The longer 60-second bound reaches only the new `DoctorCommandTests`, whose slowest row waits out `AgentCommandDoctor.defaultTimeLimit`; a hang there still fails the test at 60 s, under the suite's own 5-minute backstop, so nothing is hidden.
      4. Exit codes verified against §9. `AcpClientExitCode.forDoctorStatus(_:)` maps ok→0, warning→5, error→1, and `usage` stays 2. Measured: `doctor -- no-such-agent-xyz` exits 1, writes 1873 bytes to stdout and 0 bytes to stderr, and the command that resolved to nothing is the first ROW of the report ("error   the agent command"), with a fix line, followed by six `warning` rows that say the check did not run.
    - One correction to the stderr claim: the CLIENT writes nothing to stderr on any doctor path, and that part holds. The AGENT's own stderr is inherited and passes through: `doctor -- sh -c 'echo "agent noise on stderr" >&2; sleep 30'` put 22 bytes on the client's stderr. The spawn that inherits that descriptor is in `AgentCommandDoctor` (FoundationModelsExtras), outside this delta, and showing an agent's own diagnostics to a person running a doctor is reasonable. Recorded so the claim is read as scoped to the client.
    - `--frames` card ^3et20e2 is right to be separate. Wiring it needs a seam through `AgentCommandDoctor`, which owns the tee its rows read, so the change is in another type and another package, not in this delta.
    - next: /commit is already done for 58883fe. `Record the CLI decisions in cli-plan.md and README.md` (^bgsxs2) is unblocked.
  timestamp: 2026-09-05T01:00:27.544426+00:00
- actor: claude-code
  id: 01m1qhaqjw0pe6pabem5rf5cgj
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files. `doctor` runs `AgentCommandDoctor` through `DoctorRunner`, writes the report to stdout plain or `--json`, and exits through `AcpClientExitCode.forDoctorStatus(_:)`. `SubcommandNotImplementedError.swift` is deleted; `doctor` was its last thrower. The card's stale `Sources/acp-client/` path is corrected.
    - test: green — root 201 passed in 15 suites, integration 60 passed in 9 suites with 10 new, 0 warnings on both builds. RED first: 23 issues over the 10 new tests before the body existed.
    - commit: 58883fe feat(cli): implement doctor subcommand with report, --json, and exit codes
    - review: clean — zero findings, task moved to done

    The review measured the built binary rather than reading the code:
    - Ignoring `--timeout` is right, and it is not a special case. The option's own help text says it ends the run if the TURN does not stop in time, and a doctor runs no turn. All four §6.1 options are inert here: `--frames`, `--timeout 0`, `--timeout=-1`, `--verbose` and `--cwd /tmp` all give byte-identical output. So no command-line number can reach `min(settleInterval, timeLimit)` and collapse it — the hazard the ^btzvb81 review raised cannot happen.
    - Exit codes: ok→0, warning→5, error→1, usage pinned at 2. `doctor -- no-such-agent` exits 1 and writes the failure as the FIRST ROW with a fix line, followed by six warning rows, and zero bytes on stderr.

    One correction the review made to the implementer's claim: the client writes nothing to stderr on any doctor path, but the AGENT's own stderr is inherited and passes through. That is defensible — a person diagnosing an agent wants to see what it complains about — and it means the well-behaved-agent test's empty-stderr assertion tests the client and the silent stub together.

    One error in the review's own prose, for the record: it places `AgentCommandDoctor` in `FoundationModelsExtras`. That type is ours, in `Sources/AcpClientCore/`. The conclusion it drew is unaffected, because the inherited descriptor comes from `AgentProcess` either way.

    `--frames` shaping nothing is filed as ^3et20e2, and the review agreed a separate card is right: three sibling options are equally inert, all four are documented at the head of `DoctorCommand.swift` with a reason each, and `--frames` needs a seam through `AgentCommandDoctor`, which owns the tee its rows read.
  timestamp: 2026-09-05T01:01:06.524331+00:00
depends_on:
- 01M1MQQ5T3KQWESKQ2AT3Y93W4
- 01M1MPC2YVFK0A9NX4T9H4M0EV
- 01M1MPARCGY1FHKNED47MDBWG8
position_column: done
position_ordinal: 9f80
title: 'Implement the doctor subcommand: render the report, --json, and exit 0, 1 or 5'
---
## What

`cli-plan.md` §10 and §9. `probe` says what an agent supports; `doctor` says
whether it is usable, and its exit code carries the verdict.

Edit `Sources/AcpClientCore/DoctorCommand.swift` (the card first said
`Sources/acp-client/DoctorCommand.swift`; that path went stale when the
executable was split into a library target and a thin `@main`, and the
implementer corrected it):

- Build one `AgentCommandDoctor` over the given command, and run it through
  `FoundationModelsExtras.DoctorRunner`, which gives a `DoctorReport`.
- Write the report to **stdout**. §8 makes `doctor` an exception to the stdout
  rule, because its report is its output. The plain form comes from
  `PlainTextDoctorRenderer`; pass `useColor` true only when stdout is a
  terminal. `--json` writes `DoctorReport.jsonData(prettyPrinted:)` instead.
- Exit through `AcpClientExitCode.forDoctorStatus(report.worstStatus)`: 0 for
  `ok`, 5 for `warning`, 1 for `error`. Do **not** use
  `DoctorReport.exitCode`, which is the Extras convention: §9 says code 5
  exists here because the Rust doctor's code 2 for errors would collide with
  this binary's usage error. Write that reason as a comment at the call site,
  so a later reader does not "simplify" it back.

## Acceptance Criteria

- [x] `acp-client doctor -- <wellBehavedAgent>` prints a report to stdout and
      exits 0.
- [x] `acp-client doctor -- <bannerOnStdoutAgent>` reports that row as an
      error and exits 1.
- [x] `acp-client doctor -- <silentAgent>` reports a timeout, not a hang, and
      exits 1.
- [x] An agent whose worst status is `warning` exits 5, and never 2.
- [x] `acp-client doctor -- does-not-exist` exits 1 and names the command.
- [x] `--json` writes valid JSON to stdout, holding one entry per check with
      its name, status, message and fix.
- [x] A usage error still exits 2, so 2 and 5 never collide.

## Tests

- [x] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/DoctorCommandTests.swift`,
      one test per acceptance row above, driving the real binary through
      `runAcpClient(_:)`.
- [x] One test parses the `--json` output with `JSONSerialization` and asserts
      the check entries hold a non-empty `fix` for every `error` status.
- [x] One test runs `acp-client doctor` with no `--` and asserts exit 2, which
      pins that the doctor codes and the usage code stay apart.
- [x] One test asserts the plain-text report holds a line for every check the
      §10 table names.
- [x] One test drives `--timeout 0` and `--timeout=-1` and asserts every row
      still passes, which pins that no number off the command line can reach
      `AgentCommandDoctor`'s own time limit and collapse it to zero.
- [x] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-04 19:53)

> Scope: `review sha 58883fe~1..58883fe` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 6 not reviewed.

Zero findings. Seven validator sets ran over the delta and confirmed nothing.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> ⚠️ five tool rules of `code-hygiene` (`disallowed-constructs-swift`,
> `function-length-swift`, `idioms-swift`, `magic-numbers-swift`,
> `missing-docs-swift`) each declined one item: they found no file at
> `Sources/AcpClientCore/SubcommandNotImplementedError.swift`, because this
> change DELETES that file. A deleted file has nothing left to read, so the
> decline is the expected answer and not a gap in the review.
