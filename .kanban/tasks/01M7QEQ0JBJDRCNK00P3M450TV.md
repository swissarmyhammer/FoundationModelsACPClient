---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qghgg184j76wjkcsxrf5d3
  text: |-
    Discoveries and work:
    - The new members are in `Sources/FoundationModelsACPClient/Model/SessionModel+Export.swift`, next to `SessionModel+Markdown.swift`. `exportFileName` calls `SessionSlug.make(from:)` of FoundationModelsExtras. There is no copy of the slug rule. The short id uses a named constant `shortIDLength = 7`, and the doc comments tell that it must stay equal to `SessionSummary.shortID`. `exportFolder` is `URL(fileURLWithPath: cwd.rawValue, isDirectory: true)`.
    - Tests: `Tests/FoundationModelsACPClientTests/Model/SessionModelExportTests.swift` (7 tests, one with 3 arguments). The short id test makes a `SessionSummary` with `.init(ulidString:)` as an implicit member. The test target does not link the ULID module, and this form does not need an import of ULID.
    - The local `Package.resolved` had FoundationModelsExtras at dbbd53e. That revision has no `SessionSlug`. `Package.resolved` is not tracked, so the update is local only. Extras b87233e needs a newer mlx-swift-lm, so all pins were updated (`swift package update`), to match a fresh resolve of CI.
    - Problem: FoundationModelsKanban main (dad60cc) was built with C++ interoperability, and the test target does not enable it. The test build stops with "module 'FoundationModelsKanban' was built with C++ interoperability enabled". Local work-around: the local `Package.resolved` holds FoundationModelsKanban at d07d5b0. CI resolves fresh, so CI can fail. New task ^epzsg1p records this. The push of this task must wait for that task, or CI goes red.
  timestamp: 2026-11-18T14:21:31.009469+00:00
- actor: claude-code
  id: 01m7qghk6hjdr5fd32xdj7dpac
  text: |-
    ### implement — changed
    - evidence: 2 new files — Sources/FoundationModelsACPClient/Model/SessionModel+Export.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelExportTests.swift. `swift build`: exit 0, only the MLX "missing creator for mutated node" warning. `swift test`: 895 tests in 75 suites passed, exit 0, only the MLX warning. RED seen first (no member `exportFileName` / `exportFolder`), then GREEN (7 tests in 1 suite).
    - next: review. The acceptance item "Push main" is still open for the orchestrator. Before the push, see ^epzsg1p (FoundationModelsKanban main needs C++ interoperability; a fresh resolve in CI can fail).
  timestamp: 2026-11-18T14:21:33.777208+00:00
- actor: claude-code
  id: 01m7qgkm0sjz4vjx1bcbszgj1f
  text: |-
    ### test — green
    - evidence: swift test (root package, Package.resolved unchanged, FoundationModelsKanban pin stays at d07d5b0) — 895 tests in 75 suites passed, 0 failed, 0 skipped. The only warning is the allowed MLX "missing creator for mutated node" for mlx-swift_Cmlx.bundle.
    - next: review
  timestamp: 2026-11-18T14:22:40.153349+00:00
- actor: claude-code
  id: 01m7qgm35jvjp3z2d39twxh8ny
  text: |-
    ### commit — changed
    - evidence: ea53e5c feat(model): a session gives its export file name and folder
    - next: none. The commit is local. It is not pushed.
  timestamp: 2026-11-18T14:22:55.666170+00:00
position_column: doing
position_ordinal: '80'
title: 'SessionModel.exportFileName and exportFolder: the default name and folder of a Markdown export (D202)'
---
## Goal

The Export as Markdown… verb of AgentViewKit (D202, TestudoApp/features/decisions.md, commit 40450ab) needs a default file name and a default folder for the save panel. The `SessionModel` gives both.

Brief: /Users/wballard/github/swissarmyhammer/.briefs/export-markdown/acpc-brief.md.

This task does not need `ACPMarkdown`.

## The slug must be the D199 slug

The file name and `@<slug>` (D199) must agree. Thus the slug comes from FoundationModelsExtras `SessionSlug.make(from:)` (Extras b87233e). This package links FoundationModelsExtras to the library target (`Package.swift:85`, and many files in `Sources/` import it). Call `SessionSlug.make(from:)`. Do NOT write a copy of the slug rule. (TestudoApp asked for a copy because it thought that this package does not link Extras. It does.)

The short id rule is only on the instance property `SessionSummary.shortID` (`Sources/FoundationModelsExtras/Sessions/SessionSummary.swift:73-75`): the last 7 characters of the ULID text, in lower case. There is no static function for a bare `SessionId`. Apply the same rule to the text of `sessionId` here, and write in the doc comment that it must stay equal to `SessionSummary.shortID`.

## Current state

- `SessionModel.sessionInfo` (`Model/SessionModel.swift:162`) holds the title that the agent sends. `cwd: AbsolutePath?` is at `:99`. `sessionId` is at `:69`.

## Change

1. `public var exportFileName: String` on `SessionModel`: `SessionSlug.make(from: title)`, then `.md`. When there is no title, or the slug is empty, use the short id (above), then `.md`. For our agent the title is the session name, so the name is the slug of D199 (b).
2. `public var exportFolder: URL?` on `SessionModel`: the file URL of `cwd`, or `nil` when the model has no `cwd`.
3. Doc comments in STE. The doc comment of `exportFileName` tells that the name is `SessionSlug.make` (the D199 slug) and that the short id must stay equal to `SessionSummary.shortID`.

## Tests (Swift Testing)

Use the cases of `FoundationModelsExtras/Tests/FoundationModelsExtrasTests/Sessions/SessionSlugTests.swift`:

- [x] The title "Fix the API tests" gives `fix-the-api-tests.md`.
- [x] The title "  --Hello__World!! " gives `hello-world.md`.
- [x] The title "Café Ünïcode" gives `café-ünïcode.md`.
- [x] The title "!!!" (an empty slug) gives the short id with `.md`.
- [x] No title gives the short id with `.md`. The short id of a known ULID is its last 7 characters in lower case (compare with `SessionSummary.shortID` of the same id).
- [x] A `session_info_update` that changes the title changes `exportFileName`.
- [x] `exportFolder` is the URL of the `cwd` of the model, and `nil` with no `cwd`.

## Acceptance

- [x] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`. Send the sha to agentviewkit-0b and testudoapp-9a together with the sha of the `markdown(options:)` task. #d202