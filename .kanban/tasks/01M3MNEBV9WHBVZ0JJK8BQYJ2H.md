---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mqw9rs1cj177zvc3w8xs44
  text: |-
    ### finish — skipped (blocked on another board)
    - evidence (2026-09-28): FoundationModelsExtras OTel A ^65xmgkv is in done, but its commit a61bbb0 is not on origin/main. FoundationModelsExtras OTel B ^z6jqd9g (TelemetryTestSupport) is in doing; its commit 9b97617 is not on origin/main. `git fetch` shows origin/main at 4a733cd.
    - reason: this package pins FoundationModelsExtras with `branch: "main"` over SSH, so the `TelemetryTestSupport` product and the new floors are not available. The card says: do not start until they are done and pushed.
    - next: run `/finish` again after both Extras tasks are done and pushed.
  timestamp: 2026-09-28T19:29:14.009343+00:00
- actor: claude-code
  id: 01m3mtwm4jmecwg0ekpvpbdtdw
  text: |-
    ### Note from swissarmyhammer-05 (2026-09-28)
    - Extras OTel A to D are done locally, but they are not on origin/main yet. The Extras session pushes after its user approves. Do not start until they are on origin/main.
    - The vocabulary file gives a logger label only. Do not put a `static let` `Logger` or metric in `ACPClientTelemetry`: a logger or a metric that is made before the first `TelemetryCapture` does not go to the capture.
  timestamp: 2026-09-28T20:21:50.354765+00:00
- actor: claude-code
  id: 01m3mv3vp6jyyhyq5yqkb9mbhr
  text: |-
    ### Unblocked (2026-09-28)
    - FoundationModelsExtras OTel A to D are on origin/main (HEAD 70ad74d; checked with `git fetch` and `git merge-base --is-ancestor`). Commits: a61bbb0 (swift-log, swift-metrics), 9b97617 (TelemetryTestSupport), 736820a (TracedCall), 927033f (ExtrasTelemetry).
    - Before you start: run `swift package update FoundationModelsExtras` in this package, so that Package.resolved takes 70ad74d or later.
    - Use the floors of the Extras manifest: swift-log `from: "1.15.1"`, swift-metrics `from: "2.11.0"`.
  timestamp: 2026-09-28T20:25:47.462791+00:00
- actor: claude-code
  id: 01m3mwf1s56erd2aatb6676xd1
  text: |-
    ### Research (implement)
    - `swift package update FoundationModelsExtras` done. Package.resolved now pins FoundationModelsExtras at 70ad74d, swift-metrics 2.11.0, swift-distributed-tracing 1.5.0, swift-service-context 1.3.0.
    - Model files: FoundationModelsRouter `RouterTracing.swift` (nested enums, private prefix) and FoundationModelsExtras `ExtrasTelemetry.swift` (logLabel, SpanName, AttributeKey, MetricName, LogMetadataKey, a `makeLogger()` at call time).
    - `Sources/` has no bootstrap call, no `import os` and no `OSSignposter` today, so the scan tests are guards that pass on the current tree.
    - cli-plan.md §12 lists the five dependencies of `AcpClientCore`, not the dependencies of the library target. The new API products go on `FoundationModelsACPClient` only, so the count stays 5.
    - plan.md says the library "Depends on the wire only (decided)". This task adds the three telemetry API products to the library. plan.md is not in the card scope; I record this divergence here.
    - Decision: one span name `FoundationModelsACPClient.request` with the ACP method in `rpc.method` (bounded span-name cardinality). Error code key: `rpc.jsonrpc.error_code` (OTel JSON-RPC semantic convention). Session id key: `session.id` (OTel general attribute registry).
  timestamp: 2026-09-28T20:49:22.725743+00:00
- actor: claude-code
  id: 01m3mx81hnpygbbyhehzh8xgr9
  text: |-
    ### Implementation landed
    - Package.swift: swift-distributed-tracing `from: "1.4.1"`, swift-log `from: "1.15.1"`, swift-metrics `from: "2.11.0"`. `Tracing`, `Logging`, `Metrics` go on the `FoundationModelsACPClient` target only. `TelemetryTestSupport` goes on the test target. No target names swift-otel.
    - New `Sources/FoundationModelsACPClient/Telemetry/ACPClientTelemetry.swift`: `public enum ACPClientTelemetry` with a private `prefix`, `logLabel` = `FoundationModelsACPClient.client`, `SpanName.request`, `AttributeKey` (`rpc.method`, `session.id`, `rpc.jsonrpc.error_code`), `MetricName` (`requests`, `request.duration`, `request.errors`), `LogMetadataKey` (the same keys as the attributes). No stored logger or metric.
    - The logger label must start with `FoundationModelsACPClient.` (the card acceptance criterion), so it is not the bare module name that ExtrasTelemetry uses.
    - Tests: new `Tests/FoundationModelsACPClientTests/Telemetry/ACPClientTelemetryVocabularyTests.swift` (6 tests). ManifestTests: 2 new tests (library links the three APIs; only `acp-client` may name `swift-otel` or `OTel`). cli-plan.md §12: one paragraph about the API products and the backend rule.
    - TDD: the manifest test failed first (9 ran, 1 issue). The vocabulary test failed to compile first (`cannot find 'ACPClientTelemetry'`). Mutation check: a probe file in `Sources/AcpClientCore` with `import os`, `LoggingSystem.bootstrap` and `OSSignposter` made both scan tests fail with 2 issues; the probe is deleted.
    - Package.resolved (root and IntegrationTests) is in .gitignore, so the Extras update to 70ad74d shows no git change. `swift build --package-path IntegrationTests --build-tests` succeeds.
    - SwiftPM writes "failed loading cached manifest ... disk I/O error" warnings for its global manifest cache. These come from the machine, not from the code; there are no compiler warnings.
  timestamp: 2026-09-28T21:03:01.685531+00:00
- actor: claude-code
  id: 01m3mx84f6j7y2nbahj7bvtmbn
  text: |-
    ### implement — changed
    - evidence: 5 files — Package.swift, Sources/FoundationModelsACPClient/Telemetry/ACPClientTelemetry.swift (new), Tests/FoundationModelsACPClientTests/Telemetry/ACPClientTelemetryVocabularyTests.swift (new), Tests/FoundationModelsACPClientTests/ManifestTests.swift, cli-plan.md. `swift test --parallel`: 239 tests in 22 suites passed, 0 failures. `swift test --filter 'FoundationModelsACPClientTests\.(ACPClientTelemetryVocabularyTests|ManifestTests)'`: 15 tests passed.
    - next: /review. Divergence to record: plan.md still says the library "Depends on the wire only (decided)"; it now also links the three telemetry APIs.
  timestamp: 2026-09-28T21:03:04.678149+00:00
- actor: claude-code
  id: 01m3mxd3m4f595kbwf0pwhqvwn
  text: |-
    ### test — green
    - evidence: `swift test --parallel` — 239 tests in 22 suites passed, 0 failed, 0 skipped, 0 compiler warnings. `swift build --package-path IntegrationTests --build-tests` — build complete, exit 0. Only SwiftPM "disk I/O error" manifest-cache warnings appeared (machine noise, not code); no compiler warnings from package code.
    - next: hand off to review.
  timestamp: 2026-09-28T21:05:47.652129+00:00
- actor: claude-code
  id: 01m3mxe73205f1sj1n2fegycef
  text: |-
    ### commit — changed
    - evidence: 4494c5e feat(telemetry): add the ACPClientTelemetry vocabulary and the telemetry APIs
    - staged: Package.swift, cli-plan.md, Tests/FoundationModelsACPClientTests/ManifestTests.swift, Sources/FoundationModelsACPClient/Telemetry/ACPClientTelemetry.swift, Tests/FoundationModelsACPClientTests/Telemetry/ACPClientTelemetryVocabularyTests.swift, and the .kanban task/tag files
    - next: none, the commit is local only
  timestamp: 2026-09-28T21:06:23.970238+00:00
- actor: claude-code
  id: 01m3mxxhwbdg7ktky6mvwbafth
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 4494c5e). 0 findings (confirmed 0, refuted 0; 7 validator runs, 0 failed). The engine reviewed 4 files. It did not review 15 files: 14 files in `.kanban/` (the `.reviewignore` file excludes them) and `cli-plan.md` (no validator matches it). The task had no earlier review findings.
    - next: The task is in `done`. The dependent tasks OTel A (^yhzdf4k) and OTel B (^p8tmn6v) can start.
  timestamp: 2026-09-28T21:14:46.539683+00:00
- actor: claude-code
  id: 01m3mxy2gc6q3amn8xeqb4vbkh
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files (Package.swift, ACPClientTelemetry.swift, ACPClientTelemetryVocabularyTests.swift, ManifestTests.swift, cli-plan.md)
    - test: green — swift test --parallel, 239 tests in 22 suites passed; IntegrationTests build passed
    - commit: 4494c5e
    - review: clean — 0 findings; task moved to done
    - open question for a person: plan.md says the library "Depends on the wire only (decided)"; the library now also links Tracing, Logging and Metrics. plan.md was not changed.
  timestamp: 2026-09-28T21:15:03.564935+00:00
position_column: done
position_ordinal: b380
title: 'OTel D1: add the ACPClientTelemetry vocabulary file and the telemetry API dependencies'
---
## What

Part D (first half) of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). The swissarmyhammer-05 session asked for this task. Rule 1: a library uses only the APIs `Tracing` (swift-distributed-tracing), `Logging` (swift-log) and `Metrics` (swift-metrics). Rule 3: each package has one vocabulary file. The model is `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Tracing/RouterTracing.swift` (nested `enum SpanName` with a private `prefix`).

Current state (checked 2026-09-28): no file in `Sources/` uses `os.Logger` or `OSSignposter`. Diagnostics go through `ACPLogger` from FoundationModelsACP (`Sources/AcpClientCore/TerminalOutput.swift:155`). `Package.swift` has no direct dependency on swift-distributed-tracing, swift-log or swift-metrics (Noora pulls swift-log transitively). `Tests/FoundationModelsACPClientTests/ManifestTests.swift` pins `AcpClientCore` to exactly 5 dependencies (`permittedDependencyCount`, `theTargetDeclaresFiveDependencies`), and `cli-plan.md` §12 says the same.

This task adds the names and the dependencies only. Tasks A (spans), C (metrics) and D2 (content-safety test) use them.

- [ ] `Package.swift`: add `swift-distributed-tracing`, `swift-log` and `swift-metrics` package dependencies (use the same floors that FoundationModelsExtras uses after Extras OTel A, ^65xmgkv). Add the `Tracing`, `Logging` and `Metrics` products to the `FoundationModelsACPClient` library target. Add a comment in the style of the other dependencies: API only, no backend; only the `acp-client` executable bootstraps a backend (task B). No target gets `swift-otel`.
- [ ] `Package.swift`: add `.product(name: "TelemetryTestSupport", package: "FoundationModelsExtras")` to the `FoundationModelsACPClientTests` test target, for tasks A, C and D2.
- [ ] New file `Sources/FoundationModelsACPClient/Telemetry/ACPClientTelemetry.swift`: a `public enum ACPClientTelemetry` with nested `SpanName`, `AttributeKey`, `MetricName` and `LogMetadataKey` enums. Each name starts with the prefix `FoundationModelsACPClient.`. Give at least: the span name form for one outgoing request (`FoundationModelsACPClient.request` with the ACP method as an attribute, or one name per method; decide and document), the attribute keys `rpc.method`, session id and error code (follow OpenTelemetry semantic conventions where one exists, and document the choice), the metric names for request count, request duration and request errors, and a logger label.
- [ ] Doc comments in ASD-STE100 Simplified Technical English. State rule 4 (no content) on the enum: values are ids, method names, counts, durations and error codes only.
- [ ] Update `Tests/FoundationModelsACPClientTests/ManifestTests.swift` for the new library dependencies (the `AcpClientCore` count stays 5 if the new products go on `FoundationModelsACPClient` only), and update `cli-plan.md` §12 text if it lists the library's dependencies.

## Acceptance Criteria
- [ ] `swift build` succeeds, and the `FoundationModelsACPClient` target imports `Tracing`, `Logging` and `Metrics` with no backend call (`LoggingSystem.bootstrap`, `MetricsSystem.bootstrap`, `InstrumentationSystem.bootstrap`, `OTel.bootstrap`) anywhere in `Sources/FoundationModelsACPClient` or `Sources/AcpClientCore`.
- [ ] Every span name, metric name and logger label in `ACPClientTelemetry` starts with `FoundationModelsACPClient.`.
- [ ] No target except `acp-client` can depend on `swift-otel` (a test enforces it).
- [ ] The test target can `import TelemetryTestSupport`.

## Tests
- [ ] New `Tests/FoundationModelsACPClientTests/Telemetry/ACPClientTelemetryVocabularyTests.swift`: checks the prefix of each name, and scans `Sources/FoundationModelsACPClient` and `Sources/AcpClientCore` (use `RepositoryFile.swiftSourceFiles(under:)`) for the four bootstrap calls and for `import os` / `OSSignposter`, and fails on each hit.
- [ ] In `ManifestTests.swift`: add a test that no target other than `acp-client` names a `swift-otel` product, through the existing `swift package dump-package` reader.
- [ ] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.
- Blocked by work on another board: FoundationModelsExtras OTel A (^65xmgkv, 01M3MN838VZ4QX57C3965XMGKV) for the version floors, and FoundationModelsExtras OTel B (^z6jqd9g, 01M3MN8N9P4RPET2V5JZ6JQD9G) for the `TelemetryTestSupport` product. Do not start until they are done and pushed. #otel