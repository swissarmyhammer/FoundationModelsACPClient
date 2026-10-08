---
comments:
- actor: claude-code
  id: 01m4dx46taapmmh97hnpzx8e34
  text: |-
    Research: the client package had no resources and no `defaultLocalization`. EditorKit (EditorCommandsUI/Localization.swift) is the family pattern: a `Localizable.xcstrings` at the target root, `.process("Localizable.xcstrings")`, dot-path keys with `extractionState: manual`, and `Bundle.module.localizedString(forKey:value:table:)`. A missing key gives the key back, so a missing entry is easy to see.

    Implementation:
    - Package.swift: `defaultLocalization: "en"` and `resources: [.process("Localizable.xcstrings")]` on the FoundationModelsACPClient target.
    - Sources/FoundationModelsACPClient/Localizable.xcstrings: five keys, `auth.failure.request`, `auth.failure.terminal.message`, `auth.failure.terminal.exitStatus` (`%d`), `auth.failure.terminal.abnormalStop`, `auth.failure.unsupported`.
    - AuthFailure.swift: internal `AuthFailure.Reason.MessageKey` (String, CaseIterable) with `bundle`, `text` and `text(formatting:)`. `message` reads each text through it. The private `terminalMessage(exitStatus:)` helper is gone.
    - Decision: the agent writes the request error message, and the host writes the terminal failure message. The catalog does not translate these texts. Their keys hold the format `%@`, so a translation can add words around the text, and the English text stays the same.
    - Tests: Tests/FoundationModelsACPClientTests/Model/AuthFailureMessageTests.swift. One test checks the English text of each reason (6 cases). One test checks that each MessageKey has an entry in the compiled en.lproj (5 cases). RED: 11 issues (no en.lproj, keys given back). GREEN after the catalog entries.
  timestamp: 2026-10-08T14:01:56.810572+00:00
- actor: claude-code
  id: 01m4dx49d6ybk8dsa9w7qkwpg5
  text: |-
    ### implement — changed
    - evidence: 4 files — Package.swift, Sources/FoundationModelsACPClient/Localizable.xcstrings, Sources/FoundationModelsACPClient/Model/AuthFailure.swift, Tests/FoundationModelsACPClientTests/Model/AuthFailureMessageTests.swift. `swift test`: 588 tests in 51 suites passed. `swift build --build-tests --package-path IntegrationTests`: Build complete. Only warning is the accepted mlx-swift "missing creator for mutated node" warning (^zws9qzt).
    - next: /review
  timestamp: 2026-10-08T14:01:59.462535+00:00
- actor: claude-code
  id: 01m4dx7yxywxj1d27y4d2cjqj1
  text: |-
    ### test - green
    - evidence: swift test - 588 tests in 51 suites passed, 0 failed, 0 skipped. No compiler warning from a file of this package. swift build --build-tests in IntegrationTests - Build complete.
    - note: only the accepted mlx-swift SwiftPM warning "missing creator for mutated node" shows (task ^zws9qzt). It does not make the outcome red.
    - next: review
  timestamp: 2026-10-08T14:03:59.806515+00:00
- actor: claude-code
  id: 01m4dxcbr5kb2c2qsqbkexxmdg
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 1 finding (1 confirmed, 0 refuted) — Sources/FoundationModelsACPClient/Model/AuthFailure.swift:117 (swift/preconditions)
    - next: implement the open item in the "Review Findings (2026-10-08 09:04)" section, then review again.
  timestamp: 2026-10-08T14:06:24.005458+00:00
- actor: claude-code
  id: 01m4dxcmtsgxbvmvg1n91b6b19
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 4 files
    - test: green — swift test, 588 passed, 0 failed, 0 skipped
    - commit: 164d1e7
    - review: findings — Sources/FoundationModelsACPClient/Model/AuthFailure.swift:117
  timestamp: 2026-10-08T14:06:33.305635+00:00
- actor: claude-code
  id: 01m4dxmrs0ef81fw22k17j7ak6
  text: |-
    Fix for the swift/preconditions finding (AuthFailure.swift, `MessageKey.text`):
    - `text` now calls the new internal `text(in:reportingMissingEntry:)`. When the result of `localizedString` is equal to `rawValue`, a `guard` sends the key to the report closure and returns the key.
    - The production report is `MessageKey.recordMissingEntry(_:)`. It calls `assertionFailure("no catalog entry for <key>")` and writes `Logger(label: ACPClientTelemetry.logLabel).error(...)` with the key in the text and in the metadata key `localization.key` (`MessageKey.missingEntryMetadataKey`). This is the same pattern as `recordKindMismatch` in TranscriptEntry.swift and `recordDefect` in SessionModel.swift.
    - Why a report closure: the assertion stops a debug test run, so a test cannot reach the missing-entry path through `text`. The closure is the seam.
    - Other silent fallbacks in the file: none. The `message` switch is exhaustive, and `text(formatting:)` reads `text`, so the check also covers it.
    - Tests (AuthFailureMessageTests.swift): `aKeyWithNoCatalogEntryGivesTheKeyAndReportsIt` (Bundle.main of the test runner has no catalog) and `aKeyWithACatalogEntryReportsNothing`, each for all 5 keys. RED: build error, `text(in:reportingMissingEntry:)` did not exist. GREEN: 4 tests in 1 suite passed.
  timestamp: 2026-10-08T14:10:59.488029+00:00
- actor: claude-code
  id: 01m4dxmv6rfnq75axt0rhry4z0
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPClient/Model/AuthFailure.swift, Tests/FoundationModelsACPClientTests/Model/AuthFailureMessageTests.swift. `swift test`: 590 tests in 51 suites passed. `swift build --build-tests --package-path IntegrationTests`: Build complete. Only warning is the accepted mlx-swift "missing creator for mutated node" warning (^zws9qzt). Finding AuthFailure.swift:117 swift/preconditions is checked.
    - next: /review
  timestamp: 2026-10-08T14:11:01.976360+00:00
- actor: claude-code
  id: 01m4dxqjafz8k7kth7qxyk6ht2
  text: |-
    ### test — green
    - evidence: swift test — 590 tests in 51 suites passed, 0 failed, 0 skipped. swift build --package-path IntegrationTests --build-tests — Build complete. Zero warnings from a file of this package.
    - note: Only the accepted mlx-swift SwiftPM warning "missing creator for mutated node" appears (task ^zws9qzt). It does not make the outcome red.
    - next: review
  timestamp: 2026-10-08T14:12:31.183155+00:00
position_column: doing
position_ordinal: '80'
title: Localize the text of AuthFailure.Reason.message
---
## What
Request from AgentViewKit (task ^fh4y0d7 there). AgentViewKit now shows `AuthFailure.Reason.message` for each sign-in failure, with no kit text table, because the kit views bind directly to the client model. The client texts are not localized. Before this change, the kit had localized texts for the terminal failures (`String(localized:)`).

- [x] Make the text of `AuthFailure.Reason.message` localizable (for example `String(localized:bundle:)` with a string catalog in the client package), for each reason: request, terminal, unsupported.
- [x] Keep the English text the same as now, so current callers and tests do not change.

## Acceptance Criteria
- [x] Each text of `AuthFailure.Reason.message` comes from a localizable string resource of the client package.

## Tests
- [x] A test checks the English text of each reason.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-10-08 09:04)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsACPClient/Localizable.xcstrings` — no validator matches this file

- [x] `Sources/FoundationModelsACPClient/Model/AuthFailure.swift:117` `swift/preconditions` — When the string catalog has no entry for a key, `text` returns the raw key with no assertion and no log. The key is expected to exist for every case, so a missing entry is a surprise. The code answers it with silence, and no developer or release build records the defect. Detect the missing entry, call `assertionFailure` with the key, and write a `logger.error` line that names the key. Return the key as the fallback, as the doc comment already says. Example: compare the result of `localizedString` with `rawValue`, and when they match, call `assertionFailure("no catalog entry for \(rawValue)")` and log the same text before returning the key.
