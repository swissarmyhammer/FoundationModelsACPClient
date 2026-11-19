---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7sydksts94f8qdv8bqhfdfr
  text: |-
    The external dependency is satisfied: FoundationModelsACP origin/main dd3a981 (from foundationmodelsacp-be).
    - `SessionEntry.ID.searchHitID` writes `<kind>:<wire id>`. `SessionEntry.ID(searchHitID:)` reads it. The type is also `LosslessStringConvertible` (`description` / `init?(_:)`).
    - Kinds: user, agent, thought, tool, terminal, plan, compaction, message, and `position:<n>` for `unidentified(position:)`. The wire id is all the text after the first `:`. The table is in the doc comment. The chunker uses it. Keep no copy.
    - For the local index of the app: `SessionSearchChunker.chunks(of: wireEntries, dates: [:])`. `dates` is optional.
    Order: start after 01M7SY6JA3QTH4HNRREV28T8MB (depends_on) and ^f2kmt6m.
  timestamp: 2026-11-19T13:02:32.250133+00:00
depends_on:
- 01M7SY6JA3QTH4HNRREV28T8MB
position_column: todo
position_ordinal: '8180'
title: 'The text form of a wire id: adopt SessionEntry.ID text form of FoundationModelsACP for search hits (D207)'
---
## External dependency: do not start before it is on main

FoundationModelsACP must have ONE text form of `SessionEntry.ID` (a description and a failable init from the text, for example `LosslessStringConvertible`). The session foundationmodelsacp-be was asked for it on 2026-11-19 and sends the sha.

## Why the form is in FoundationModelsACP

The acpc brief (item 2) proposes the parse in this package, and the acp brief (item 3) tells the chunker to use "the form that FoundationModelsACPClient parses". But the chunker is in FoundationModelsACP, and FoundationModelsACP cannot depend on this package. `SessionEntry.ID` is a type of FoundationModelsACP (an enum with the cases userMessage, agentMessage, agentThought, toolCall, terminal, plan, compaction, sessionMessage, unidentified(position:)). Thus both directions of the text form go in FoundationModelsACP, next to the type. This package uses them and writes no second copy.

Brief: /Users/wballard/github/swissarmyhammer/.briefs/search/acpc-brief.md (item 2).

## Change

1. Update FoundationModelsACP to the sha with the text form.
2. In the doc comment of `SessionModel.entry(forWireID:)` (from 01M7SY6JA3QTH4HNRREV28T8MB), tell that a search hit gives the id in the text form of `SessionEntry.ID`, and name the API of FoundationModelsACP that parses it.
3. If a convenience is necessary for the app, add `entry(forWireText:)` that parses with the API of FoundationModelsACP and calls `entry(forWireID:)`. Add it only if AgentViewKit or the app needs it; otherwise do not.

## Tests (Swift Testing)

- [ ] The text form of each `SessionEntry.ID` case goes and comes back with no change, and the parsed id gives the same entry with `entry(forWireID:)`.

## Acceptance

- [ ] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning.
- [ ] Push `main`, and send the sha to agentviewkit-0b and testudoapp-9a. #d207