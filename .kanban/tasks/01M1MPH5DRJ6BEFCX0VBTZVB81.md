---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1q290v9kvhvf52p2p1jkxcy
  text: |-
    Research done. What the sources really say, for the next agent:

    - `Doctorable` (`.build/checkouts/FoundationModelsExtras/Sources/FoundationModelsExtras/Doctor/Doctorable.swift`) declares `doctorName`, `doctorCategory`, `isApplicable` (default `true`) and `func runHealthChecks() async -> [HealthCheck]` (non-throwing, with a default implementation). The protocol refines `Sendable`.
    - `HealthStatus` has three cases only: `ok`, `warning`, `error`. There is NO `skipped` case. So "a skipped check is reported, not omitted" must be a `warning` whose message says the check did not run and whose `fix` names the earlier finding to repair. A `warning` is safe: `cli-plan.md` §9 ranks an error over a warning, so a report that skipped a row because row 1 failed still exits 1 for that failure.
    - `HealthCheck.ok(name:message:category:)` takes no fix; `warning`/`error` require one.
    - Check 2 works against a conformant agent. `AgentProcess`'s reader thread calls `AgentProcessState.terminateCurrent()` on stdout EOF, which clears the pid, so `AgentProcess.processIdentifier` becoming `nil` after a settle interval is exactly "the agent is gone". A conformant agent blocks on its stdin and keeps its pid. No hazard there.
    - `processExists(_:)` already exists in `IntegrationTests/.../Support/TransportTestSupport.swift`; `temporaryFileURL(prefix:)` in `Support/TemporaryFiles.swift`; the stub `pidFile:` parameter writes `$$`.
    - `ExitCodeTests` scans `Sources/acp-client` and fails any line of CODE that mentions "exit" (case-insensitive) and also spells a decimal number, so the new file must not put a digit on a line naming an exit.
  timestamp: 2026-09-04T20:38:01.833350+00:00
- actor: claude-code
  id: 01m1q29y931kdxmy2aj2xpvn61
  text: |-
    BLOCKER — the two halves of this card cannot both hold with the build graph as it stands.

    The card asks for the code in `Sources/acp-client/AgentCommandDoctor.swift` (the EXECUTABLE target) and for the tests in `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`, driving the type "directly, not through the binary". A test target in the nested package cannot import the executable target of the root package.

    Evidence, measured and not guessed:

    1. `IntegrationTests/Package.swift` already names `.product(name: "acp-client", package: "FoundationModelsACPClient")`. With `import acp_client` added to a file of that target, `swift build --package-path IntegrationTests --build-tests` fails at dependency scanning:
       `error: ... AgentCommandDoctorTests.swift:5:8 unable to resolve module dependency: 'acp_client'`
    2. `IntegrationTests/.build/out/Products/Debug/` holds the built `acp-client` BINARY and a `.swiftmodule` for every library (`FoundationModelsACPClient`, `FoundationModelsACP`, `FoundationModelsExtras`, `Noora`, ...). There is no `acp_client.swiftmodule` at all. The module is never emitted for a cross-package executable dependency, so this is not a `@testable` problem: plain `import acp_client` fails the same way.
    3. `--build-system native` DOES emit it: the same build under that flag got past the import and reported only `cannot find 'AgentCommandDoctor' in scope`, which is the wanted RED. But `swift build --help` reports `--build-system` default `swiftbuild`, `native` is marked deprecated, and `.github/workflows/ci.yml` runs the shared `swift-ci.yaml` with no build-system input. So a suite that compiles only under `native` is a suite CI cannot run.
    4. The root unit target CAN `@testable import acp_client` (same package; `AgentSessionTests`, `ProbeReportTests` and others already do). It is the only target that can reach the type today. But check 2 spawns a real agent, and this repository forbids that there: `Tests/FoundationModelsACPClientTests/AgentProcessTests.swift` states "No test in this file spawns a process. The tests that spawn a real foreign agent over stdio live in the nested IntegrationTests package", `IntegrationTests/Package.swift` states the split is "a property of the build graph, not a convention", and the `test-partitioning` validator flags an integration test inside the unit target. No unit test spawns a process today; a grep over `Tests/` finds none.

    So this is a true conflict between two requirements of the card, not a choice an implementer may make quietly. A person has to pick one of:

    A. Put the checks in the LIBRARY target `Sources/FoundationModelsACPClient/`. It already holds `AgentProcess` and already links `FoundationModelsExtras`, so `Doctorable` is in reach and `IntegrationTests` can `@testable import FoundationModelsACPClient` today. Cost: `AgentCommandResolver` must stay in the binary (its own header states why the library refuses a PATH lookup), so the doctor would take the resolution as an injected closure and check 1's per-case `fix` text would sit on the other side of the seam. The check is then split over two targets.

    B. Split `acp-client` into a thin executable (`AcpClient.swift` alone) plus a new LIBRARY target and product holding the rest, which is the usual SwiftPM shape for a cross-package-testable CLI. Cost: it moves ~15 files, changes `cli-plan.md` §3 ("Path: `Sources/acp-client/`"), and touches `ManifestTests`, `TerminalOutputTests` and `ExitCodeTests`, each of which scans or pins `Sources/acp-client`. This is its own card.

    C. Keep the code where the card says and test it in the integration suite THROUGH the binary, which needs the `doctor` subcommand of ^39xrxnp first — that card currently depends on this one, so the two would swap order and this card's "not through the binary" line would go.

    D. Accept the process spawns inside the root unit target, against the split above.

    Nothing was left half-built: the working tree is back to `HEAD` (the new test file removed, `IntegrationTests/Package.swift` and `Support/StubAgents.swift` reverted), so both suites still build and run as before.

    The design that was ready to write, so it is not lost:

    - `struct AgentCommandDoctor: Doctorable` holding `command`, `arguments`, `resolver: AgentCommandResolver`, `timeLimit: Duration` (its own, never `--timeout`); `doctorName` is `command`, `doctorCategory` one shared constant.
    - `runHealthChecks()` resolves first. On failure it returns `[.error(commandCheckName, message: String(describing: error), fix: <per-case>), skipped(processCheckName, after: commandCheckName)]`, where `skipped` is a `warning`. On success it returns `[.ok(commandCheckName, ...), await processCheck(for: executable)]`.
    - `processCheck` spawns `AgentProcess`, `defer { process.shutdown() }`, polls `processIdentifier` until `min(settleInterval, timeLimit)` ends or the pid is gone, then reports `error` for a pid that went away and `ok` for one that stayed.
    - The stub the tests need: `makeExitingAtOnceAgent()` in `Support/StubAgents.swift`, one line, `exit 127`, plus a shared `recordedAgentPid(in:)` reader beside it (two private copies of that reader already stand in `ProbeCommandTests` and `RunCommandExitTests`).
  timestamp: 2026-09-04T20:38:31.971261+00:00
- actor: claude-code
  id: 01m1q2avv4d8kykf8p34m74s7z
  text: |-
    ### implement — stuck
    - evidence: no files changed; the working tree is back to HEAD. `timeout 420 swift test` — 199 tests in 14 suites passed. `timeout 600 swift test --package-path IntegrationTests` — 34 tests in 6 suites passed. The card's Tests section cannot compile: a test target in the nested `IntegrationTests` package cannot import the root package's EXECUTABLE target, so `import acp_client` fails with `unable to resolve module dependency: 'acp_client'` and no `acp_client.swiftmodule` is ever emitted under the default `swiftbuild` build system. See the BLOCKER comment above for the measurements and the four options.
    - next: a person picks where the checks live (library target, split executable, test through the binary, or accept spawns in the unit target), then this card is re-run with that decision written into it.
  timestamp: 2026-09-04T20:39:02.244363+00:00
- actor: claude-code
  id: 01m1qcaxw1nw7w54fhrg9wgym2
  text: |-
    Picked up again, now that the blocker is answered. Option B landed before this run: `Sources/acp-client/` holds `AcpClientMain.swift` alone, and `Sources/AcpClientCore/` holds the seventeen files the CLI is made of, as a library TARGET and PRODUCT. `IntegrationTests/Package.swift` already names `.product(name: "AcpClientCore", ...)`, and `AcpClientCoreImportTests.swift` proves the boundary compiles under the default build system.

    So the card's file paths change from `Sources/acp-client/AgentCommandDoctor.swift` to `Sources/AcpClientCore/AgentCommandDoctor.swift`. I updated the description to say so.

    Fresh research, on top of what the earlier comment still holds:

    - The unit suite already reaches the library with `@testable import AcpClientCore` in ten files, and the integration suite already reaches the OTHER library with `@testable import FoundationModelsACPClient` in `StubAgents.swift` and `TransportTestSupport.swift`. A cross-package `@testable` import therefore works in this graph today. The new integration test uses `@testable import AcpClientCore`, so the doctor stays `internal` and the library grows no new public API.
    - `ExitCodeTests.ExitCodeLiteralScan` reads `SourceFiles.commandLineClientDirectories`, which is now `["Sources/AcpClientCore", "Sources/acp-client"]`. The new file must put no decimal number on a line of CODE that also spells "exit". Comments and string literals are stripped first, so only code lines matter.
    - `AgentCommandResolver.resolve(_:)` is declared `throws` without a type, and it throws `AgentCommandResolutionFailure` alone. A doctor that gives each case its own `fix` must switch over the cases exhaustively, and an untyped `catch` forces an unreachable second branch. The two call sites (`RunCommand`, `ProbeCommand`) both catch untyped inside a `do`, so narrowing the signature to `throws(AgentCommandResolutionFailure)` costs them nothing.
    - `AgentProcess` reaps on stdout EOF, so `processIdentifier` going `nil` is exactly "the agent is gone". `makeSilentAgent()` and `makeWellBehavedAgent()` both block on stdin and keep their pid.
  timestamp: 2026-09-04T23:33:50.081496+00:00
- actor: claude-code
  id: 01m1qcz04n5khnxsd545j7jk6g
  text: |-
    Implementation landed. What is worth knowing next time:

    **Check 2 works as the card wrote it.** Nothing had to change. A conformant ACP agent blocks reading its stdin while it waits for `initialize`, so its stdout stays open and `AgentProcess.processIdentifier` stays set. An agent whose runtime is missing closes stdout at once, the reader thread reaches EOF, `AgentProcessState.terminateCurrent()` clears the pid, and the row reports the failure. Both halves are measured against real `/bin/sh` agents, and both pass.

    **The watch, not a sleep.** `startedAgentCheck` polls `processIdentifier` every 20 ms until it goes away or `min(settleInterval, timeLimit)` ends. So the failing case answers in about 20 ms rather than spending the whole interval, and only the passing case pays the 500 ms. That is why the six new integration tests add about two seconds in total and not six.

    **The time limit.** `AgentCommandDoctor` holds `timeLimit`, its own, defaulting to ten seconds, and check 2 spends `min(Self.settleInterval, timeLimit)` of it. `settleInterval` is 500 ms. The two are separate because checks 3 to 7 will want the whole limit for one `initialize`, and a settle window that grew with the limit would make a patient doctor a slow one. Neither is `--timeout`: that option bounds the turn a person asked for.

    **One signature change outside this file.** `AgentCommandResolver.resolve(_:)` is now `throws(AgentCommandResolutionFailure)` rather than untyped `throws`, and the two private helpers it calls with it. The doctor gives each failure case its own `fix`, so it must switch over the cases exhaustively; an untyped `catch` would have forced an unreachable second branch, which is dead code by another name. The two call sites, `RunCommand.runTurn` and `ProbeCommand.probeAgent`, both `try` inside a `do` with an untyped `catch`, so narrowing the signature cost them nothing and neither file changed.

    **A unit suite was added beyond the card's list**, `Tests/FoundationModelsACPClientTests/AgentCommandDoctorTests.swift`, one test. Two reasons. First, the half of row 1 that fails to resolve starts no process, so by the repository's own split it belongs in the unit target, and the four `AgentCommandResolutionFailure` cases are cheap to drive there and expensive to drive through a spawn. Second, the `dead-code-swift` scan reads the ROOT package alone: it never sees the nested `IntegrationTests` package, so a type only that package names looks unused. The unit test is what keeps `AgentCommandDoctor` reachable until the `doctor` subcommand of ^39xrxnp calls it.

    **`IntegrationTests/Package.swift` gained one dependency**, `FoundationModelsExtras`, restated verbatim from `../Package.swift` as that manifest's header requires. The doctor suite asserts on `HealthCheck` and `HealthStatus` directly, and a test target should name where its types come from rather than rest on a transitive import. It costs no new checkout: the root package already resolves that package. `ManifestTests` reads the ROOT manifest only, and its pin of five `AcpClientCore` dependencies still passes — this task needed no sixth.

    **Two private pid readers folded into one.** `recordedAgentPid(in:)` now stands in `Support/StubAgents.swift`, beside the statement that writes the file, and `ProbeCommandTests` and `RunCommandExitTests` call it instead of each keeping a copy. Adding a third copy would have been a duplication finding; this removes the two that stood.

    **Pre-checks run before reporting.** swiftlint over the changed Swift files with `no_magic_numbers`, `missing_docs`, `function_body_length`, `closure_body_length` and the five force-construct rules: clean. `periphery scan` could NOT run here — it wants an index store at `.build/debug/index/store`, and the default `swiftbuild` build system writes `.build/out/` instead, so it reports `index store path does not exist`. Producing one needs `--build-system native`, which this repository does not use. So the dead-code check rests on the unit test above rather than on a measurement.
  timestamp: 2026-09-04T23:44:47.765424+00:00
- actor: claude-code
  id: 01m1qczg3rfwwkzd1hge6k7vvm
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/AcpClientCore/AgentCommandDoctor.swift (new), Sources/AcpClientCore/AgentCommandResolver.swift, Tests/FoundationModelsACPClientTests/AgentCommandDoctorTests.swift (new), IntegrationTests/Package.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift (new), .../Support/StubAgents.swift, .../ProbeCommandTests.swift, .../RunCommandExitTests.swift. `timeout 420 swift test` — 201 tests in 15 suites passed, zero warnings. `timeout 600 swift test --package-path IntegrationTests` — 41 tests in 8 suites passed, zero warnings. RED was measured first: `swift build --package-path IntegrationTests --build-tests` reported `cannot find type 'AgentCommandDoctor' in scope` before the source file was written. Every acceptance row and every test row of the description is ticked; no row was left undone.
    - next: /review. The `doctor` subcommand that renders these checks is ^39xrxnp and was out of scope here, so `DoctorCommand.run()` still throws `SubcommandNotImplementedError`.
  timestamp: 2026-09-04T23:45:04.120622+00:00
- actor: claude-code
  id: 01m1qd8hd6vjfkn87a2s2zymgr
  text: |-
    ### review — clean
    - evidence: `review sha c8b0a59~1..c8b0a59` — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed, 0 skipped. 8 files reviewed.
    - checked by hand, on request: (1) check 2 cannot report a false failure on a slow agent — `AgentProcess.init` records the pid at the spawn, and only stdout EOF clears it, so an agent that blocks on stdin holds its pid for the full watch; (2) the typed throw on `AgentCommandResolver.resolve(_:)` breaks no caller — `RunCommand`, `ProbeCommand` and the resolver tests all call it from untyped `throws` contexts, and the four `AgentCommandResolutionFailure` cases stay reachable; (3) §11 holds — `defer { agent.shutdown() }` stands after the spawn succeeds, and the resolve-failure path starts no process; (4) the `warning` for a row that did not run hides nothing — it is only ever returned beside the `error` row that dominates the exit code of §9; (5) the tests drive the doctor value, not the source text.
    - next: none. Card is done. Checks 3 to 7 belong to ^0jrf7 and ^93w4.
  timestamp: 2026-09-04T23:50:00.358919+00:00
- actor: claude-code
  id: 01m1qd9nbfeeafhaw8vyryr25t
  text: |-
    ### finish iteration 1 — clean
    This card was stuck once, and the block is gone: `AgentCommandDoctor` lives in the new `AcpClientCore` library, which both suites can import.

    - implement: changed — 8 files. `struct AgentCommandDoctor: Doctorable` resolves the command, starts the agent, and reports both rows whichever way the first went. `AgentCommandResolver.resolve(_:)` gained a typed throw so the doctor can switch the failure cases exhaustively.
    - test: green — root 201 passed in 15 suites, integration 41 passed in 8 suites, 0 warnings on both
    - commit: c8b0a59 feat(doctor): add AgentCommandDoctor for command resolution and process start checks
    - review: clean — zero findings, task moved to done

    The four points the review settled:
    - Check 2's premise holds. `AgentProcess` records the pid synchronously inside `init`, and only stdout EOF, a read failure or `shutdown()` clear it. A conformant agent that blocks on stdin writes nothing and closes nothing, so the watch runs its full window and reports `ok`. Slowness alone cannot make a false failure, because the check never waits for output — it asks only whether the child is still there.
    - The typed throw narrows nothing. Both callers sit inside untyped `throws` functions, which a typed throw widens into, and every case the resolver could report before it can still report.
    - §11 holds on every path. The `defer` sits after the `AgentProcess` init succeeds; the failed-init return has no process, and the resolve-failure branch returns before any spawn. An integration test proves it against a real pid read back from a file.
    - The `warning` row hides no failure. It is reachable from one place only, so it always stands beside the `error` row that caused it, and §9 ranks `error` above `warning`, so the exit code still carries the failure.

    One observation the review raised, outside this delta and not a finding: `min(settleInterval, timeLimit)` collapses to zero if a caller ever passes a zero or negative `timeLimit`, which would give a false `ok`, never a false failure. Nothing constructs the doctor that way today. The CLI wiring is ^39xrxnp — check it there.
  timestamp: 2026-09-04T23:50:37.167346+00:00
depends_on:
- 01M1Q5ZSJXM50HEWDVXW83ZSHZ
position_column: done
position_ordinal: 9c80
title: 'Doctor checks 1 and 2: the command resolves, and the process starts and stays'
---
## What

`cli-plan.md` §10, the `Doctorable` scaffolding and the first two rows of the
check table. The protocol, the runner and the plain renderer come from
`FoundationModelsExtras`, under
`Sources/FoundationModelsExtras/Doctor/`. This package writes one conformance
over an agent command; it writes no doctor framework.

Create `Sources/AcpClientCore/AgentCommandDoctor.swift`:

- `struct AgentCommandDoctor: Doctorable`. It holds the raw agent command, its
  arguments, an `AgentCommandResolver`, and a time limit that belongs to the
  doctor alone and is **not** shared with `--timeout`.
- The protocol's members are `doctorName` and `doctorCategory`, and
  `func runHealthChecks() async -> [HealthCheck]` is **not** throwing. Read
  `Doctorable.swift` before writing the conformance, and use the exact names.
  `doctorName` is the agent command as the person typed it; `doctorCategory` is
  one constant every check shares.
- `runHealthChecks()` runs the checks in order and skips the later ones when an
  earlier one made them meaningless: a command that does not resolve cannot be
  started. A skipped check is reported, not omitted, so the report always has
  the same shape.

The two checks of this task:

1. **The command resolves.** Run `AgentCommandResolver.resolve(_:)`. Each
   `AgentCommandResolutionFailure` case becomes an `error` check whose `fix`
   text names the mistake: a typing mistake, or a binary that was not built.
2. **The process starts, and it does not exit at once.** Spawn with
   `AgentProcess`, wait a short settle interval, and read
   `AgentProcess.processIdentifier`. An agent that is gone is an `error`, and
   the `fix` names a missing runtime or a crash on start. Tear the process
   down whatever the outcome.

Checks 3 to 7 all need a live ACP connection, so they belong to the two
following tasks.

The path above says `Sources/AcpClientCore/` and no longer
`Sources/acp-client/`. Card ^83zshz split the client into the `AcpClientCore`
library and a thin `acp-client` executable holding the `@main` type alone,
which is what lets the nested `IntegrationTests` package drive this type
directly. The `Tests` section below carries the same change.

## Acceptance Criteria

- [x] `AgentCommandDoctor` conforms to `Doctorable`, with `doctorName`,
      `doctorCategory` and a non-throwing `runHealthChecks()`.
- [x] Every returned value is built with the Extras `ok`, `warning` and
      `error` factories.
- [x] A command that is not on `PATH` gives one `error` check, and the later
      checks are reported as skipped rather than dropped.
- [x] An agent that exits at once gives an `error` check on row 2.
- [x] `wellBehavedAgent` gives `ok` on both rows.
- [x] No agent process outlives `runHealthChecks()`, whatever the outcome.

## Tests

- [x] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`.
      It drives `AgentCommandDoctor` directly, not through the binary, so each
      check is asserted on its own. Use the `StubAgents` helpers.
- [x] One test per acceptance row above, asserting the check `name`, `status`
      and that `fix` is not empty for each `error`.
- [x] Extend `StubAgents` with an agent that exits at once.
- [x] One test records the spawned pid and asserts `kill(pid, 0)` reports the
      process is gone after `runHealthChecks()`.
- [x] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.
- [x] New `Tests/FoundationModelsACPClientTests/AgentCommandDoctorTests.swift`,
      added beyond the list above. It drives the four
      `AgentCommandResolutionFailure` cases and asserts that each names a
      repair of its own. That half of row 1 starts no process, so it belongs
      in the unit target; it is also what keeps the type reachable from the
      root package, which the dead-code scan reads.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.