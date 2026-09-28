---
assignees:
- claude-code
depends_on:
- 01M3MNEBV9WHBVZ0JJK8BQYJ2H
position_column: todo
position_ordinal: '8380'
title: 'OTel B: bootstrap swift-otel in the acp-client executable, and keep stdout for the answer only'
---
## What

Part B of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rule 1: only an executable depends on `swift-otel` and calls `OTel.bootstrap`; the standard `OTEL_*` environment variables configure it. Rule 6: an executable must always bootstrap logging. The swift-log default handler writes to stdout, and `cli-plan.md` §8 keeps stdout for the answer text alone.

Current state (checked 2026-09-28):
- `Sources/acp-client/AcpClientMain.swift` holds only `@main struct AcpClientMain` that calls `AcpClient.main()`.
- `Package.swift`: the `acp-client` target depends on `AcpClientCore` alone. `ManifestTests.theExecutableTargetTakesTheLibraryAlone` (`Tests/FoundationModelsACPClientTests/ManifestTests.swift`) enforces that, and `cli-plan.md` §3 and §12 say it.
- Noora pulls swift-log, but Noora never calls `LoggingSystem.bootstrap`; its components take an optional `Logger` that `TerminalOutput` does not give. Stderr belongs to `TerminalOutput` (`Sources/AcpClientCore/TerminalOutput.swift`).

The flush of the exporters before the process exits is task B2, not this task.

- [ ] `Package.swift`: add `swift-otel` (`https://github.com/swift-otel/swift-otel.git`, the current release) and give its `OTel` product to the `acp-client` executable target only. Update `ManifestTests` (the executable may take `AcpClientCore` and `OTel` only; no other target may name `swift-otel`) and the text of `cli-plan.md` §3 and §12.
- [ ] New file `Sources/acp-client/TelemetryBootstrap.swift`, called first in `AcpClientMain.main()`: when `OTEL_EXPORTER_OTLP_ENDPOINT` is set, call `OTel.bootstrap` for logs, traces and metrics. When it is not set, bootstrap logging with `SwiftLogNoOpLogHandler` (recommended: stderr belongs to `TerminalOutput`, and the ACP diagnostics already reach it through `ACPLogger`), and leave tracing and metrics as no-op. Never use a stdout handler.
- [ ] Doc comments in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] Without `OTEL_EXPORTER_OTLP_ENDPOINT`, `acp-client run` gives stdout that holds the answer text only, and stderr has no new log lines.
- [ ] With `OTEL_EXPORTER_OTLP_ENDPOINT` set to a local port where nothing listens, `acp-client run` still exits 0 and stdout holds the answer text only.
- [ ] Only the `acp-client` target depends on `swift-otel`.

## Tests
- [ ] New `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/TelemetryBootstrapTests.swift`: use `runAcpClient(...)` and `acpClientBinaryURL()` from `Support/CLITestSupport.swift` with a stub agent from `Support/StubAgents.swift`. Case 1: no `OTEL_*` variables; stdout equals the stub answer and stderr is the same as a run before this change (no log lines). Case 2: `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:<closed port>`; exit code 0 and stdout equals the stub answer.
- [ ] Update `Tests/FoundationModelsACPClientTests/ManifestTests.swift` as above.
- [ ] `swift test --parallel` and `swift test --package-path IntegrationTests` pass. With `--filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`. #otel