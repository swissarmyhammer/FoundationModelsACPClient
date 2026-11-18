---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qbr132smna853jvd7bgw41
  text: |-
    Research: `ObservableTranscriptEntry` already requires `meta: JSONValue?`, but the card names only two types. Thus the property is on `SessionMessageEntry` and `UserMessageEntry` only, not on a protocol extension. A `session_message` `_meta` patch replaces each top-level key, so a second upsert replaces the whole `sah` object and `sahMessage` gives the newest title.

    Formatting: the repo has no `.swift-format` file (none in git history and none in a parent folder). `swift format -i -r Sources Tests` with no config uses the default 2-space indent and 100-column lines, and it changes almost every file in the repo. I did not run it. I wrote the new code in the 4-space style of the files near it. The orchestrator must decide about the format step.

    Implementation: added computed `sahMessage` (returns `SAH.SessionMessage.extract(from: meta)`) to both entries, and 7 Swift Testing tests in SessionModelSessionMessageTests.swift. The test `_meta` comes from `SAH.SessionMessage(sender:).inject(into: nil)`. RED was a compile failure (no member `sahMessage`); GREEN: 12/12 tests pass.
  timestamp: 2026-11-18T12:57:41.730706+00:00
- actor: claude-code
  id: 01m7qbr3skftwzyx413enetrfm
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPClient/Model/SessionMessageEntry.swift, Sources/FoundationModelsACPClient/Model/UserMessageEntry.swift, Tests/FoundationModelsACPClientTests/Model/SessionModelSessionMessageTests.swift; `swift build --build-tests` has only the allowed MLX warning; `swift test --filter 'FoundationModelsACPClientTests.SessionModelSessionMessageTests'` gives 12 passed, 0 failed.
    - next: review. `swift format` not run, because the repo has no `.swift-format`. The TestudoApp reply is open for the orchestrator.
  timestamp: 2026-11-18T12:57:44.499073+00:00
- actor: claude-code
  id: 01m7qbsevjmyhqp80kbndssmgh
  text: |-
    ### test — green
    - evidence: swift test (root package) — 880 tests in 73 suites passed, 0 failed, 0 skipped. Only warning: the allowed MLX "missing creator for mutated node" for mlx-swift_Cmlx.bundle.
    - next: review
  timestamp: 2026-11-18T12:58:28.594630+00:00
- actor: claude-code
  id: 01m7qbswvz61718d7nzhh4jfhw
  text: |-
    ### commit — changed
    - evidence: 06bcaf8 feat(model): a message entry gives its typed sah message
    - next: review
  timestamp: 2026-11-18T12:58:42.943434+00:00
position_column: doing
position_ordinal: '80'
title: Add a typed sender accessor `sahMessage` to SessionMessageEntry (D199)
---
## Goal

AgentViewKit shows "From the user, in <title>" or "From <title>" on a message from another session (D199 (f), TestudoApp/features/decisions.md, commit 740cd1a). It must get the typed sender of `_meta.sah.message` from the entry. It must not parse the raw `JSONValue`.

Brief: /Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpc-brief-at-sessions.md. Plan: impact-at-sessions.md in the same folder.

No dependency. This task is optional for the send, and it is small.

## Current behavior

- `SessionMessageEntry` (`Sources/FoundationModelsACPClient/Model/SessionMessageEntry.swift`) keeps the raw `_meta` as `meta: JSONValue?`. `copy(_:)` sets it from `message.meta.currentValue`.
- `UserMessageEntry.meta` (`Sources/FoundationModelsACPClient/Model/UserMessageEntry.swift`) is also raw. Nothing reads it.
- The typed wire type is `SAH.SessionMessage` with `static func extract(from: JSONValue?) -> SessionMessage?` (`FoundationModelsACP/Sources/FoundationModelsACP/SAH/SAHMeta.swift`). The `Sender` has `kind` (`user`, `session`), `sessionId`, `title`, `agent` and `cwd`.

## Change

1. Add a computed property `public var sahMessage: SAH.SessionMessage?` to `SessionMessageEntry`. It returns `SAH.SessionMessage.extract(from: meta)`. It returns `nil` when there is no `_meta`, or when `_meta` has no `sah.message`. Because it reads the observed `meta`, a view that reads it updates when `meta` changes. Do not store a second copy.
2. Add the same computed property to `UserMessageEntry`, for a later host that sends the source on a user message. Keep the two doc comments in STE.

## Tests (Swift Testing, in `Tests/FoundationModelsACPClientTests/Model/SessionModelSessionMessageTests.swift`)

- [x] A `session_message` update with `_meta.sah.message` of kind `user` gives an entry whose `sahMessage` has the kind, the sender session id and the title.
- [x] A `session_message` update with kind `session` gives the kind `session`, the session id, the title, the agent and the folder.
- [x] An entry with no `_meta` gives `nil`.
- [x] An entry with a `_meta` that has no `sah.message` gives `nil`.
- [x] An entry upserted two times keeps the newest `_meta`: `sahMessage` shows the second title.
- [x] A `UserMessageEntry` with `_meta.sah.message` gives the typed value, and with no `_meta` gives `nil`.

Make the `_meta` with `SAH.SessionMessage(...).inject(into: nil)`, not with hand-written JSON.

## Acceptance

- [ ] `swift build` and `swift test` pass with no new warnings.
- [ ] Reply to the TestudoApp session (testudoapp-9a) when the change is on main, so that AgentViewKit can use it. #d199