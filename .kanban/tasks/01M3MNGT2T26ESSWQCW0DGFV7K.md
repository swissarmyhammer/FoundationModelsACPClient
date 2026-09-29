---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3n7p32fppxzpa021egp1rr5
  text: |-
    Research (implement step):
    - swift-otel 1.5.1: `OTel.bootstrap(configuration:)` returns `some Service` (a `ServiceGroup` of the enabled backends). `OTel.makeLoggingBackend(configuration:)` returns `(factory, service)`. Both services are discarded now, so the logs service must be kept too, not only the traces and metrics service.
    - The batch span processor flushes and shuts its exporter down when the service gets a graceful shutdown. So the flush path is: run a `ServiceGroup` over the kept services, run the command, call `triggerGracefulShutdown()`, and wait.
    - swift-service-lifecycle 2.12.0: `ServiceGroup(services:logger:)`, `run()`, `triggerGracefulShutdown()`. `maximumGracefulShutdownDuration` escalates to cancellation, and `maximumCancellationDuration` escalates to `fatalError`. So these do not give a safe time bound. The bound must be our own race: the process exits at the first of (the services finished) or (the bound ended). The exit must occur inside the task group, because a task group waits for all its children.
    - `ManifestTests` lets the `acp-client` target take only `AcpClientCore` and `OTel`. `ServiceLifecycle` is a module that `OTel` brings in, and `TelemetryBootstrap.swift` already imports `Logging` the same way. So `import ServiceLifecycle` needs no manifest change.
    - ArgumentParser 1.8.2 `exit(withError:)`: a `.help` message (help, version, CleanExit) goes to stdout with `print`, and every other nonempty message goes to stderr. A nonempty message has the success code only for `.help`. So "exit code is success -> stdout, else stderr" gives the same destination. The `disallowed-constructs-swift` rule forbids `print`, so `run()` writes with `FileHandle` and adds the same "\n" that `print` adds.
    - `TelemetryBootstrapSourceTests` pins the first statement of `main()`. That statement becomes `let telemetry = TelemetryBootstrap.bootstrap()`, so the pinned text changes with it. The invariant (bootstrap first) stays.
    - `ExitCodeTests` scans `Sources/` for a line that holds "exit" and a decimal number. New constant names must not hold "exit".
  timestamp: 2026-09-29T00:05:27.759254+00:00
- actor: claude-code
  id: 01m3n8aqw1tg2y00p74vgq93ag
  text: |-
    Implementation landed (not committed):
    - `AcpClient.run(_ arguments: [String]? = nil) async -> Int32` in AcpClientCore. `main()` is now `Darwin.exit(await run())`. A private `report(_:)` writes the message of the error: stdout when the parser code is success (help, version, CleanExit), else stderr. It uses `FileHandle`, not `print`.
    - New `Sources/acp-client/TelemetryServices.swift`: keeps the export services, runs them in a `ServiceGroup` (silent logger), runs the command, calls `triggerGracefulShutdown()`, and exits at the first of (the group finished) or (`shutdownBound` = 2 s). The exit is inside the task group.
    - `TelemetryBootstrap.bootstrap()` now returns `TelemetryServices`, and keeps the logs service from `makeLoggingBackend` and the traces and metrics service from `OTel.bootstrap`.
    - `AcpClientMain.main()`: `let telemetry = TelemetryBootstrap.bootstrap()` then `await telemetry.runThenExit { await AcpClient.run() }`.
    - Integration: new `Support/OTLPTestReceiver.swift` (127.0.0.1, free port, one thread for each connection, records the path before it answers; a `.none` mode never answers). `LoopbackSocket` holds the bind helper that `closedPortEndpoint()` used before.
    Discovery: with the endpoint on a CLOSED port, the exporter shutdown does not end by itself (the run hung past the 10 s test limit when the bound was 30 s). So the bound is needed for a closed port too, not only for a silent collector. A closed-port run now takes about 2 s more than before.
    RED checks seen: unit tests failed to compile before `run(_:)` existed; the delivery test failed with `requestPaths == []` before the services ran; both timing tests failed (10 s run limit) with the bound set to 30 s for one run.
  timestamp: 2026-09-29T00:16:44.417273+00:00
- actor: claude-code
  id: 01m3n8g7x3a2d3vjbctbxxwz57
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/AcpClientCore/AcpClient.swift, Sources/acp-client/AcpClientMain.swift, Sources/acp-client/TelemetryBootstrap.swift, Sources/acp-client/TelemetryServices.swift (new), Tests/FoundationModelsACPClientTests/ExitCodeTests.swift, Tests/FoundationModelsACPClientTests/Telemetry/TelemetryBootstrapSourceTests.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/TelemetryBootstrapTests.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/OTLPTestReceiver.swift (new). `swift test --parallel`: 257 tests in 26 suites passed. `swift test --package-path IntegrationTests`: 103 tests in 14 suites passed. Filtered runs: ExitCodeTests|CommandParsingTests 25 tests, TelemetryBootstrapTests 9 tests. No compiler warnings (only SwiftPM manifest-cache "disk I/O error" warnings from the environment).
    - next: /review. Not committed. Task stays in doing.
  timestamp: 2026-09-29T00:19:44.675575+00:00
- actor: claude-code
  id: 01m3n8s41967t4w76sex0925na
  text: |-
    ### test — green
    - evidence: `swift test --parallel` (main package) — 257 tests passed, 0 failed, 0 skipped. `swift test --package-path IntegrationTests`, run 1 — 103 tests passed, 0 failed, 0 skipped. `swift test --package-path IntegrationTests`, run 2 (repeat for the timing-bound tests) — 103 tests passed, 0 failed, 0 skipped.
    - No compiler warnings from this package's code in any run.
    - Each run showed 88 SwiftPM manifest-cache "disk I/O error" warnings (e.g. "failed loading cached manifest for 'swift-system': disk I/O error"). These are noise from the shared dependency cache, not from this package's code, and do not count against the result.
    - next: send to review.
  timestamp: 2026-09-29T00:24:35.625611+00:00
- actor: claude-code
  id: 01m3n8tr4t8fe3jc8tw3faxvvx
  text: |-
    ### commit — changed
    - evidence: 2d1954b feat(telemetry): flush OTel exporters on every acp-client exit path
    - next: review
  timestamp: 2026-09-29T00:25:28.986132+00:00
- actor: claude-code
  id: 01m3n9225kb1nsfgggnvt0mcf5
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (checkpoint 2d1954b). 0 findings, 0 confirmed, 0 refuted. 7 validator runs, 0 failed. 8 files reviewed. 4 .kanban files not reviewed because of .reviewignore. The task has no prior findings sections.
    - next: None. The task moved to done.
  timestamp: 2026-09-29T00:29:28.627535+00:00
- actor: claude-code
  id: 01m3n9295f6sesmw41ptk55hn8
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files (AcpClient.swift, AcpClientMain.swift, TelemetryBootstrap.swift, TelemetryServices.swift new, ExitCodeTests.swift, TelemetryBootstrapSourceTests.swift, TelemetryBootstrapTests.swift, OTLPTestReceiver.swift new)
    - test: green — swift test --parallel 257 passed; IntegrationTests 103 passed, two runs
    - commit: 2d1954b
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-09-29T00:29:35.791573+00:00
depends_on:
- 01M3MNFZ76BJSBEDSTMP8TMN6V
position_column: done
position_ordinal: b880
title: 'OTel B2: flush the OTel exporters before acp-client exits, on every exit path'
---
## What

Second half of part B of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). After task B, `acp-client` bootstraps swift-otel when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. But an OTLP exporter sends in batches, and a process exit does not flush it. So the spans of a short run can be lost.

Current state (checked 2026-09-28): `AcpClient.main()` (`Sources/AcpClientCore/AcpClient.swift`) returns on success, and on an error it calls `exit(withError:)` (ArgumentParser) or `Darwin.exit(processExitCode(for:))`. `Sources/acp-client/AcpClientMain.swift` calls it.

- [x] In `Sources/AcpClientCore/AcpClient.swift`: add `public static func run() async -> Int32` that does what `main()` does now but returns the exit code (and writes the same stderr text) in place of calling `exit`. Keep `main()` as `exit(await run())`, so that current callers do not change. For `--help` and `--version`, keep the text and the code that `exit(withError:)` gives now (use `exitCode(for:)` and `fullMessage(for:)`; check that help text still goes to stdout as today).
- [x] In `Sources/acp-client/AcpClientMain.swift` (and `TelemetryBootstrap.swift` from task B): when OTel is on, run the OTel service (`ServiceGroup` or the lifecycle API of the pinned swift-otel release), call `AcpClient.run()`, shut the service down so that the exporters flush, with a time bound (recommended 2 seconds) so that a dead collector cannot hang the exit, and then `exit` with the code.
- [x] Doc comments in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] Every exit code of `cli-plan.md` §9 is unchanged, with and without `OTEL_EXPORTER_OTLP_ENDPOINT`.
- [x] With `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at a local test receiver, one `acp-client run` delivers its spans to the receiver before the process ends.
- [x] With the endpoint on a closed port, the process ends within the shutdown bound plus the normal run time.

## Tests
- [x] Extend `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/TelemetryBootstrapTests.swift` (task B): (1) start a small local HTTP listener in the test that accepts OTLP/HTTP POSTs on `/v1/traces` and records that a request came; set `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` to it; run `acp-client run` against a stub agent; check that at least one trace POST came before the process ended. (2) closed port: check the run ends within the bound. (3) a refusing agent and `--help` keep their §9 exit codes with OTel on.
- [x] Add a unit test in `Tests/FoundationModelsACPClientTests/ExitCodeTests.swift` that `AcpClient.run()` returns the §9 codes for a usage error and for `--version` without ending the test process (if the parser state allows it; if not, cover it in the integration test and say why in the test comment).
- [x] `swift test --parallel` and `swift test --package-path IntegrationTests` pass. With `--filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`. #otel