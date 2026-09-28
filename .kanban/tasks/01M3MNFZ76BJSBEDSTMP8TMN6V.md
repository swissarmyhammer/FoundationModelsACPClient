---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3my64temgdgg2vkv93039ap
  text: |-
    Research (implement step):
    - swift-otel current release is 1.5.1 (git ls-remote). Product `OTel`. Default traits OTLPHTTP and OTLPGRPC. API: `OTel.bootstrap(configuration:)` and `OTel.bootstrap(configuration:environment:)` return `some Service` (ServiceLifecycle). The service must run to export; task B2 runs it.
    - `OTel.bootstrap` bootstraps logs, then metrics, then traces. It can throw after it bootstrapped logs (for example a bad metrics-only certificate path). Then a fallback `LoggingSystem.bootstrap` would crash (swift-log allows one bootstrap).
    - `OTEL_SDK_DISABLED=true` makes `OTel.bootstrap` skip all three systems. Then `LoggingSystem` stays on the swift-log default handler, which writes to STDOUT. That breaks rule 6 and cli-plan.md §8.
    - The swift-otel diagnostic logger writes to stderr at level info by default ("Bootstrapping ... exporter"). cli-plan.md §8 says a default run writes nothing to stderr until it fails.
    - Plan to keep "logging is bootstrapped one time, never to stdout" true on every path: TelemetryBootstrap bootstraps logging itself, with the factory of `OTel.makeLoggingBackend` when OTel is on and that call succeeds, else with `SwiftLogNoOpLogHandler`. Then it calls `OTel.bootstrap` with logs disabled for traces and metrics. Diagnostic level `.warning`.
    - No source of the run path logs through swift-log today, so the two integration cases pass before this change too. They are guards for tasks A and C, which add log records. The red test is the ManifestTests change.
  timestamp: 2026-09-28T21:19:28.078041+00:00
- actor: claude-code
  id: 01m3mzfejdd8gj2t1jw8kktb8d
  text: |-
    Implementation landed (not committed).

    - `Package.swift`: `swift-otel` `from: "1.5.1"` (resolves to 1.5.1, rev b601415). The `acp-client` target takes `AcpClientCore` and `.product(name: "OTel", package: "swift-otel")`. The executable imports `Logging` as a module that `OTel` brings into the build. It does not name the `swift-log` product, because the card allows `AcpClientCore` and `OTel` only. The build gives no warning for this.
    - `Sources/acp-client/TelemetryBootstrap.swift`: `TelemetryBootstrap.bootstrap()` is the first statement of `AcpClientMain.main()`.

    DECISION FOR THE REVIEWER: the card says "call `OTel.bootstrap` for logs, traces and metrics". Logs do NOT go through `OTel.bootstrap`. Logs use `OTel.makeLoggingBackend(configuration:)` and one `LoggingSystem.bootstrap`. Then `OTel.bootstrap` runs with `logs.enabled = false` for traces and metrics. The reason: one `OTel.bootstrap` call cannot keep "bootstrap logging one time, never to stdout" on all paths.
      (a) `OTel.bootstrap` can throw after it bootstrapped logs. A no-op fallback after that throw would call `LoggingSystem.bootstrap` a second time, and swift-log stops the process. A no-op fallback is still necessary when the logs backend itself throws.
      (b) Logs still go to the swift-otel OTLP exporter.
      Check that I did: `OTEL_EXPORTER_OTLP_ENDPOINT=https://127.0.0.1:9 OTEL_EXPORTER_OTLP_METRICS_CERTIFICATE=/nonexistent OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf acp-client --version` exits 0, writes `0.1.0` to stdout, and writes one stderr line: `acp-client: a telemetry backend is off: serverCertificateFileNotFound("/nonexistent")`.
    - `OTEL_SDK_DISABLED=true` (the case of the letters has no effect) takes the no-op path. Without that check, `OTel.bootstrap` bootstraps nothing, and the swift-log default handler writes to stdout.
    - `diagnosticLogLevel = .warning`. At the swift-otel default level, `info`, stderr gets "Bootstrapping ..." lines on each run.
    - The `some Service` that swift-otel returns is discarded (`_ =`), and the logging backend service is not kept. No record leaves the process until B2 (^gw0dgfv) runs the services and flushes them. B2 must change `TelemetryBootstrap` so that it returns or keeps the services.

    Tests:
    - RED seen: `ManifestTests` (the executable names `OTel` from `swift-otel`; `Package.resolved` pins `swift-otel`) and the new `TelemetryBootstrapSourceTests` (the first statement of main() is `TelemetryBootstrap.bootstrap()`) failed for the expected reason before the change.
    - The 3 cases in `TelemetryBootstrapTests` (no OTEL; closed port; closed port with SDK disabled) passed before the change, because no code on the run path logs through swift-log yet. They are guards for tasks A and C.
    - To remove a duplicate, `statementLines`/`eventHandlerBody` moved out of `InterruptHandlerSourceTests.swift` into the new shared `Tests/FoundationModelsACPClientTests/SwiftSourceText.swift`. The new source test uses it too.
    - `Package.resolved` is in .gitignore, so the pin check reads the local resolution. This is the same as the Noora check.
  timestamp: 2026-09-28T21:42:01.549651+00:00
- actor: claude-code
  id: 01m3mzfk6anwae1q35j8n0tr1p
  text: |-
    ### implement — changed
    - evidence: Package.swift, Sources/acp-client/AcpClientMain.swift, Sources/acp-client/TelemetryBootstrap.swift (new), Tests/FoundationModelsACPClientTests/ManifestTests.swift, Tests/FoundationModelsACPClientTests/Telemetry/TelemetryBootstrapSourceTests.swift (new), Tests/FoundationModelsACPClientTests/SwiftSourceText.swift (new), Tests/FoundationModelsACPClientTests/InterruptHandlerSourceTests.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/TelemetryBootstrapTests.swift (new), cli-plan.md. `swift test --parallel`: 241 tests in 23 suites passed, 0 warnings from the source. `swift test --package-path IntegrationTests`: 97 tests in 14 suites passed, and the 3 TelemetryBootstrapTests ran. The filtered runs used `FoundationModelsACPClientIntegrationTests\.TelemetryBootstrapTests` (3 ran) and `FoundationModelsACPClientTests\.(ManifestTests|TelemetryBootstrapSourceTests|InterruptHandlerSourceTests)` (12 ran).
    - next: review. The reviewer must decide on the logs path: `OTel.makeLoggingBackend` in place of `OTel.bootstrap`, for the reasons in the previous comment.
  timestamp: 2026-09-28T21:42:06.282980+00:00
- actor: claude-code
  id: 01m3mzfqtjenagdfxa17tn818r
  text: 'Correction: the short id of B2 in my comment above is wrong. B2 is ^0dgfv7k (01M3MNGT2T26ESSWQCW0DGFV7K), not ^gw0dgfv.'
  timestamp: 2026-09-28T21:42:11.026318+00:00
- actor: claude-code
  id: 01m3mzs0mn7ng9vqbgzk0t9r8c
  text: |-
    ### test — green
    - evidence: `swift test --parallel` — 241 tests, 23 suites, 0 failed, 0 skipped. `swift build --build-tests` — build complete, 0 code warnings (86 SwiftPM manifest-cache "disk I/O error" lines are machine noise, not code). `swift test --package-path IntegrationTests` — 97 tests, 14 suites, 0 failed, 0 skipped (4 "skip" text hits are test names about the doctor's own row-skip logic, not skipped tests).
    - next: ready for review.
  timestamp: 2026-09-28T21:47:14.965418+00:00
depends_on:
- 01M3MNEBV9WHBVZ0JJK8BQYJ2H
position_column: doing
position_ordinal: '80'
title: 'OTel B: bootstrap swift-otel in the acp-client executable, and keep stdout for the answer only'
---
## What

Part B of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rule 1: only an executable depends on `swift-otel` and calls `OTel.bootstrap`; the standard `OTEL_*` environment variables configure it. Rule 6: an executable must always bootstrap logging. The swift-log default handler writes to stdout, and `cli-plan.md` §8 keeps stdout for the answer text alone.

Current state (checked 2026-09-28):
- `Sources/acp-client/AcpClientMain.swift` holds only `@main struct AcpClientMain` that calls `AcpClient.main()`.
- `Package.swift`: the `acp-client` target depends on `AcpClientCore` alone. `ManifestTests.theExecutableTargetTakesTheLibraryAlone` (`Tests/FoundationModelsACPClientTests/ManifestTests.swift`) enforces that, and `cli-plan.md` §3 and §12 say it.
- Noora pulls swift-log, but Noora never calls `LoggingSystem.bootstrap`; its components take an optional `Logger` that `TerminalOutput` does not give. Stderr belongs to `TerminalOutput` (`Sources/AcpClientCore/TerminalOutput.swift`).

The flush of the exporters before the process exits is task B2, not this task.

- [x] `Package.swift`: add `swift-otel` (`https://github.com/swift-otel/swift-otel.git`, the current release) and give its `OTel` product to the `acp-client` executable target only. Update `ManifestTests` (the executable may take `AcpClientCore` and `OTel` only; no other target may name `swift-otel`) and the text of `cli-plan.md` §3 and §12.
- [x] New file `Sources/acp-client/TelemetryBootstrap.swift`, called first in `AcpClientMain.main()`: when `OTEL_EXPORTER_OTLP_ENDPOINT` is set, call `OTel.bootstrap` for logs, traces and metrics. When it is not set, bootstrap logging with `SwiftLogNoOpLogHandler` (recommended: stderr belongs to `TerminalOutput`, and the ACP diagnostics already reach it through `ACPLogger`), and leave tracing and metrics as no-op. Never use a stdout handler.
- [x] Doc comments in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] Without `OTEL_EXPORTER_OTLP_ENDPOINT`, `acp-client run` gives stdout that holds the answer text only, and stderr has no new log lines.
- [x] With `OTEL_EXPORTER_OTLP_ENDPOINT` set to a local port where nothing listens, `acp-client run` still exits 0 and stdout holds the answer text only.
- [x] Only the `acp-client` target depends on `swift-otel`.

## Tests
- [x] New `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/TelemetryBootstrapTests.swift`: use `runAcpClient(...)` and `acpClientBinaryURL()` from `Support/CLITestSupport.swift` with a stub agent from `Support/StubAgents.swift`. Case 1: no `OTEL_*` variables; stdout equals the stub answer and stderr is the same as a run before this change (no log lines). Case 2: `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:<closed port>`; exit code 0 and stdout equals the stub answer.
- [x] Update `Tests/FoundationModelsACPClientTests/ManifestTests.swift` as above.
- [x] `swift test --parallel` and `swift test --package-path IntegrationTests` pass. With `--filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`. #otel