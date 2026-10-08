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