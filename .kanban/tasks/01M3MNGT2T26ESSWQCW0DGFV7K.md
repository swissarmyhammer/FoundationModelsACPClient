---
assignees:
- claude-code
depends_on:
- 01M3MNFZ76BJSBEDSTMP8TMN6V
position_column: todo
position_ordinal: '8480'
title: 'OTel B2: flush the OTel exporters before acp-client exits, on every exit path'
---
## What

Second half of part B of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). After task B, `acp-client` bootstraps swift-otel when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. But an OTLP exporter sends in batches, and a process exit does not flush it. So the spans of a short run can be lost.

Current state (checked 2026-09-28): `AcpClient.main()` (`Sources/AcpClientCore/AcpClient.swift`) returns on success, and on an error it calls `exit(withError:)` (ArgumentParser) or `Darwin.exit(processExitCode(for:))`. `Sources/acp-client/AcpClientMain.swift` calls it.

- [ ] In `Sources/AcpClientCore/AcpClient.swift`: add `public static func run() async -> Int32` that does what `main()` does now but returns the exit code (and writes the same stderr text) in place of calling `exit`. Keep `main()` as `exit(await run())`, so that current callers do not change. For `--help` and `--version`, keep the text and the code that `exit(withError:)` gives now (use `exitCode(for:)` and `fullMessage(for:)`; check that help text still goes to stdout as today).
- [ ] In `Sources/acp-client/AcpClientMain.swift` (and `TelemetryBootstrap.swift` from task B): when OTel is on, run the OTel service (`ServiceGroup` or the lifecycle API of the pinned swift-otel release), call `AcpClient.run()`, shut the service down so that the exporters flush, with a time bound (recommended 2 seconds) so that a dead collector cannot hang the exit, and then `exit` with the code.
- [ ] Doc comments in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] Every exit code of `cli-plan.md` §9 is unchanged, with and without `OTEL_EXPORTER_OTLP_ENDPOINT`.
- [ ] With `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at a local test receiver, one `acp-client run` delivers its spans to the receiver before the process ends.
- [ ] With the endpoint on a closed port, the process ends within the shutdown bound plus the normal run time.

## Tests
- [ ] Extend `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/TelemetryBootstrapTests.swift` (task B): (1) start a small local HTTP listener in the test that accepts OTLP/HTTP POSTs on `/v1/traces` and records that a request came; set `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` to it; run `acp-client run` against a stub agent; check that at least one trace POST came before the process ended. (2) closed port: check the run ends within the bound. (3) a refusing agent and `--help` keep their §9 exit codes with OTel on.
- [ ] Add a unit test in `Tests/FoundationModelsACPClientTests/ExitCodeTests.swift` that `AcpClient.run()` returns the §9 codes for a usage error and for `--version` without ending the test process (if the parser state allows it; if not, cover it in the integration test and say why in the test comment).
- [ ] `swift test --parallel` and `swift test --package-path IntegrationTests` pass. With `--filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`. #otel