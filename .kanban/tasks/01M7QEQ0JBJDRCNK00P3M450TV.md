---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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

- [ ] The title "Fix the API tests" gives `fix-the-api-tests.md`.
- [ ] The title "  --Hello__World!! " gives `hello-world.md`.
- [ ] The title "Café Ünïcode" gives `café-ünïcode.md`.
- [ ] The title "!!!" (an empty slug) gives the short id with `.md`.
- [ ] No title gives the short id with `.md`. The short id of a known ULID is its last 7 characters in lower case (compare with `SessionSummary.shortID` of the same id).
- [ ] A `session_info_update` that changes the title changes `exportFileName`.
- [ ] `exportFolder` is the URL of the `cwd` of the model, and `nil` with no `cwd`.

## Acceptance

- [ ] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`. Send the sha to agentviewkit-0b and testudoapp-9a together with the sha of the `markdown(options:)` task. #d202