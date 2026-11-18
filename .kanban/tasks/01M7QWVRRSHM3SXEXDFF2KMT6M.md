---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'forkSession(_:cut:): mark the fork as opening on the reader when FoundationModelsACP gives forkSession(_:onResponse:)'
---
## Problem

`ConnectionModel.forkSession(_:cut:)` (^nfe6mak) opens the model of the fork through the shared helper `openSession(sending:over:through:)` of `newSession(_:)`. For `session/new`, the hook `ClientSideConnection.newSession(_:onResponse:)` marks the session as opening on the reader, before the next frame. FoundationModelsACP cb9aee7 has no `forkSession(_:onResponse:)`. Thus `forkSession` calls the hook only when `connection.forkSession(_:)` returns, on the main actor.

The result: a permission request or an elicitation of the agent for the fork that comes between the fork answer and that time gets cancel from the router. The updates are not lost.

## Change

1. Ask the FoundationModelsACP session for `ClientSideConnection.forkSession(_:onResponse:)`, with the same contract as `newSession(_:onResponse:)`. Do not write to the board of FoundationModelsACP.
2. When it is on main, use it in `forkSession(_:cut:)` in `Sources/FoundationModelsACPClient/Model/ConnectionModel+Sessions.swift`, and remove the sentence about the missing hook from the doc comment.
3. Add a test in the style of the open-question tests of `newSession` (`SessionOpenQuestionTests`): a permission request of the agent for the fork directly after the fork answer is pending on the model of the fork, and not answered with cancel.

## Acceptance

- [ ] `swift build` and `swift test` pass. The only allowed warning is the MLX "missing creator for mutated node" warning. #d205