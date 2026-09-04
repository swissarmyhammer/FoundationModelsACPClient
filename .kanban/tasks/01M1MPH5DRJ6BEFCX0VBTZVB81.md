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
depends_on:
- 01M1Q5ZSJXM50HEWDVXW83ZSHZ
position_column: doing
position_ordinal: '80'
title: 'Doctor checks 1 and 2: the command resolves, and the process starts and stays'
---
## What

`cli-plan.md` §10, the `Doctorable` scaffolding and the first two rows of the
check table. The protocol, the runner and the plain renderer come from
`FoundationModelsExtras`, under
`Sources/FoundationModelsExtras/Doctor/`. This package writes one conformance
over an agent command; it writes no doctor framework.

Create `Sources/acp-client/AgentCommandDoctor.swift`:

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

## Acceptance Criteria

- [ ] `AgentCommandDoctor` conforms to `Doctorable`, with `doctorName`,
      `doctorCategory` and a non-throwing `runHealthChecks()`.
- [ ] Every returned value is built with the Extras `ok`, `warning` and
      `error` factories.
- [ ] A command that is not on `PATH` gives one `error` check, and the later
      checks are reported as skipped rather than dropped.
- [ ] An agent that exits at once gives an `error` check on row 2.
- [ ] `wellBehavedAgent` gives `ok` on both rows.
- [ ] No agent process outlives `runHealthChecks()`, whatever the outcome.

## Tests

- [ ] New
      `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`.
      It drives `AgentCommandDoctor` directly, not through the binary, so each
      check is asserted on its own. Use the `StubAgents` helpers.
- [ ] One test per acceptance row above, asserting the check `name`, `status`
      and that `fix` is not empty for each `error`.
- [ ] Extend `StubAgents` with an agent that exits at once.
- [ ] One test records the spawned pid and asserts `kill(pid, 0)` reports the
      process is gone after `runHealthChecks()`.
- [ ] Run `swift test --package-path IntegrationTests`. Every assertion
      passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.