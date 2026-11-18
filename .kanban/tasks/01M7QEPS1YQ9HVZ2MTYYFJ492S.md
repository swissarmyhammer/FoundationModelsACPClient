---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qf6v3c2h3fgppyyk116whb
  text: |-
    The external dependency is satisfied: `ACPMarkdown` is on FoundationModelsACP origin/main at 7e31ad0 (from foundationmodelsacp-be).
    - Product `ACPMarkdown`. Its target depends only on FoundationModelsACP.
    - Call `SessionMarkdown.render(entries:sessionInfo:options:)` with the wire entries in transcript order. `render(updates:options:)` folds the updates first.
    - `SessionMarkdown.Options(includeThoughts: false, title: nil, agentName: nil, labels: .english)`.
    - Golden files: FoundationModelsACP Tests/ACPMarkdownTests/Golden/*.md.
    - `SessionMergeEngine.init(replaying:)` is public in the core target now.
  timestamp: 2026-11-18T13:58:12.844242+00:00
- actor: claude-code
  id: 01m7qfp32gqak3s2xs8vs3fyq6
  text: |-
    Research and design (implement):
    - `swift package update FoundationModelsACP` resolves main at 7e31ad0. The real API is `SessionMarkdown.render(entries: [SessionEntry], sessionInfo: SessionInfoUpdate? = nil, options: Options = .init()) -> String`. `SessionEntry` has no public init, so the model can give only engine entries.
    - Important: step 2 of the card says "skip each `.local` entry". But a local user message keeps its `.local` identity after the agent links it (the card says this in "Current state"). A literal skip of each `.local` entry removes each prompt that the user typed and the agent got. Then the live document is not the same as the document of a replay, and D202 (e) fails. The rationale of the card is "a prompt that the agent did not get and a local request error are not part of the session history". Thus the implementation finds the engine identity of each transcript object through `wireEntries` (the link writes the engine id of the echo there). A pending or failed prompt and a local error have no engine identity, so they are not in the document. A linked prompt with its echo is in the document.
    - A link with no echo yet has no engine entry, so it is not in the document until the echo comes. The ACP v2 agent echoes each inserted user message.
    - New internal `SessionModel.engineTranscript` in SessionModel.swift (the `engine` is private to that file). The public `markdown(options:)` is in the new file SessionModel+Markdown.swift, the only file that imports ACPMarkdown.
    - An extra test: `aLinkedLocalUserMessageIsInTheDocument`. It fails with the literal "skip each `.local`" design.
  timestamp: 2026-11-18T14:06:32.528438+00:00
- actor: claude-code
  id: 01m7qfq1w0a6chdshy70ffaq64
  text: |-
    ### implement — changed
    - evidence: 4 files. Package.swift (ACPMarkdown on the library target and on the test target), Sources/FoundationModelsACPClient/Model/SessionModel.swift (internal `engineTranscript`), Sources/FoundationModelsACPClient/Model/SessionModel+Markdown.swift (new, public `markdown(options:)`), Tests/FoundationModelsACPClientTests/Model/SessionModelMarkdownTests.swift (new, 8 tests). `swift build`: the only warning is the MLX "missing creator for mutated node" warning. `swift test`: 888 tests in 74 suites pass, 0 failures, no other warning. The IntegrationTests package also builds after `swift package update FoundationModelsACP` there.
    - deviation, recorded: a linked and echoed local prompt is in the document (see the design comment). A literal skip of each `.local` entry would remove each prompt that the agent got.
    - next: review. The acceptance item "Push main, and send the sha" is open for the orchestrator. Nothing is committed.
  timestamp: 2026-11-18T14:07:04.064063+00:00
- actor: claude-code
  id: 01m7qfsckp4fvezmgxte2rmv82
  text: |-
    ### test — green
    - evidence: `swift test` in the root package: 888 tests in 74 suites passed, 0 failed, 0 skipped. `swift build --build-tests --package-path IntegrationTests`: build complete.
    - warnings: only the allowed MLX "missing creator for mutated node" warning for mlx-swift_Cmlx.bundle.
    - not run: the live integration tests. This step only built them.
    - next: review.
  timestamp: 2026-11-18T14:08:20.598808+00:00
- actor: claude-code
  id: 01m7qft1e6jwq9wbkan10hg05b
  text: |-
    ### commit — changed
    - evidence: 9951bda feat(model): a session gives its transcript as Markdown (local commit, not pushed)
    - next: review. Push of main and the send of the sha stay open.
  timestamp: 2026-11-18T14:08:41.926677+00:00
position_column: doing
position_ordinal: '80'
title: 'SessionModel.markdown(options:): adapt the wire transcript to ACPMarkdown (D202)'
---
## External dependency: do not start before it is on main

The `ACPMarkdown` product of FoundationModelsACP must be on `main`. The session foundationmodelsacp-be sends the sha. On 2026-11-18 it is not there yet (FoundationModelsACP `d53d876`, no `ACPMarkdown` in `Package.swift`).

## Goal

AgentViewKit exports the chat of a session as Markdown for each ACP agent (D202, TestudoApp/features/decisions.md, commit 40450ab). This package gives one call that makes the document from the ordered transcript of a `SessionModel`, with the renderer of FoundationModelsACP.

Brief: /Users/wballard/github/swissarmyhammer/.briefs/export-markdown/acpc-brief.md. Overview: overview.md in the same folder.

## Current state

- `TranscriptEntry.ID` (`Sources/FoundationModelsACPClient/Model/TranscriptEntry.swift`) is `.wire(SessionEntry.ID)` for an entry from the merge engine, or `.local(UUID)` for an entry that the client made. A local user message keeps `.local` after the agent links it to a `messageId`.
- `SessionModel.transcript` (`Model/SessionModel.swift:110`) is in the order of first appearance. `sessionInfo` is at `:162`. The private `engine` (`:368`) is a `SessionMergeEngine`. `SessionMergeEngine.entry(withID:)` gives the `SessionEntry` for a wire id.

## Change

1. In `Package.swift`, link the `ACPMarkdown` product of `FoundationModelsACP` to the `FoundationModelsACPClient` target (and to the test target if the tests call the renderer). Run `swift package update FoundationModelsACP`.
2. Add `@MainActor public func markdown(options: SessionMarkdown.Options = .init()) -> String` to `SessionModel`. It walks `transcript` in order. For each `.wire(id)` entry it takes `engine.entry(withID: id)`. It skips each `.local` entry: a prompt that the agent did not get and a local request error are not part of the session history. Thus the UI and the agent give the same document (D202 (e)). It calls `SessionMarkdown.render(entries:sessionInfo:options:)` (use the real signature of the shipped API) with `sessionInfo`.
3. Doc comments in STE.

## Tests (Swift Testing)

- [x] A model that gets a scripted update stream gives the same text as `SessionMarkdown.render(updates:)` of the same stream.
- [x] A local user message that is `pending` or `failed` is not in the document.
- [x] A local `error` entry is not in the document.
- [x] A replay into a new model (`history` with a replay) gives the same text as the live model.
- [x] Two calls on the same model give the same text (no date, no time, no random id).

## Acceptance

- [x] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`, and send the sha to agentviewkit-0b and testudoapp-9a. #d202