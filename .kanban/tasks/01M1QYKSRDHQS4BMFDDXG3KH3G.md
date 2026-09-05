---
assignees:
- claude-code
position_column: todo
position_ordinal: '9e80'
title: Replace "an other" with "another" in the Swift comments of both packages
---
## What

ASD-STE100 gives **another**. The words "an other" are not correct.

Card ^xbgsxs2 removed each "an other" from `cli-plan.md`. The same two words
stand in 15 Swift files, in doc comments and in file-header comments. Those
files are outside the scope of ^xbgsxs2, which touched the two Markdown
documents and two test files only, so the correction is this card.

## Where

Run this to get the current list:

```
rg -n "an other" --glob '*.swift'
```

At the time of writing it names files under `Sources/AcpClientCore/`,
`Tests/FoundationModelsACPClientTests/`, `IntegrationTests/`, and
`Package.swift`.

## Rules

- Change the words only. Do not change what a comment says.
- Do not touch a line that reads "the other" or "each other". Those are
  correct.
- `swift test` and `swift test --package-path IntegrationTests` must both stay
  green, because a doc comment change compiles.

## Acceptance Criteria

- [ ] `rg -n "an other"` finds nothing in this repository.
- [ ] Both test suites pass, with no warning.
