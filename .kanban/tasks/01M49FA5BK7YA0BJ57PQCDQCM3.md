---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m49hypyxsznesdarjrcn5t6w
  text: 'How to know that 34m4s52 is done: the FoundationModelsACP implementer may send the commit SHA to this session, but that is not certain. Do not wait for a message. Before you start, look at FoundationModelsACP `main` for the commit: run `git -C ../FoundationModelsACP fetch origin main` and `git -C ../FoundationModelsACP log origin/main --oneline -20`, find the commit that adds `afterRespondingToCurrentRequest(_:onDiscard:)`, and also check the 34m4s52 card on the FoundationModelsACP board.'
  timestamp: 2026-10-06T21:29:44.669758+00:00
- actor: claude-code
  id: 01m4b0ysajw1m1ax4njz7kdwj2
  text: '34m4s52 is done. The FoundationModelsACP session reports: it is on `main`, and CI is green (https://github.com/swissarmyhammer/FoundationModelsACP/actions/runs/37612159800). The feature commit is 9a32d8e. Use `main` HEAD 163f7ebbebc5c831319a618cf8ba7edde982e483 (or later) in `Package.resolved`. The API is as agreed: `afterRespondingToCurrentRequest(_:)` and `afterRespondingToCurrentRequest(_:onDiscard:)` on `ClientSideConnection` and `AgentSideConnection`. Check the commit with `git -C ../FoundationModelsACP log origin/main` before you update.'
  timestamp: 2026-10-07T11:11:10.162322+00:00
position_column: todo
position_ordinal: '8480'
title: 'Adopt FoundationModelsACP task 34m4s52: resolve the revision with ClientSideConnection.afterRespondingToCurrentRequest'
---
## What

The upstream change is planned on the FoundationModelsACP board as task **34m4s52**, "Add ClientSideConnection.afterRespondingToCurrentRequest". The FoundationModelsACP session (`foundationmodelsacp-e0`) owns that work. This task only brings the new revision into this package, so that task ^3p0m0c1 can use it.

Do not start this task before 34m4s52 is done and pushed to FoundationModelsACP `main`.

The final API of 34m4s52 is the same on `AgentSideConnection` and `ClientSideConnection`:

```swift
public func afterRespondingToCurrentRequest(_ work: @escaping @Sendable () async -> Void)   // agent side: no change
public func afterRespondingToCurrentRequest(
    _ work: @escaping @Sendable () async -> Void,
    onDiscard: @escaping @Sendable () -> Void
)
```

The contract of `onDiscard`:

- The connection calls `onDiscard` exactly one time when `work` will never run, and never when `work` runs.
- `onDiscard` is synchronous, so it is a safe place to resume a continuation.
- For a call outside an inbound request, `work` does not run, and `onDiscard` runs at once, before the method returns.
- `onDiscard` also runs for a late append (after the hooks ran or were discarded), and when the connection closes before it writes the response.

1. Run `swift package update FoundationModelsACP` in this package.
2. Make sure that `Package.resolved` names a FoundationModelsACP revision that contains 34m4s52.
3. Make sure that `ClientSideConnection.afterRespondingToCurrentRequest(_:onDiscard:)` compiles from `Sources/FoundationModelsACPClient`.

## Acceptance Criteria

- [ ] 34m4s52 is done on the FoundationModelsACP board, and its commit is on FoundationModelsACP `main`.
- [ ] `Package.resolved` names that revision, or a later one.
- [ ] `swift build` and `swift test` pass here, with no new warning.

## Tests

- No new test in this package. Task ^3p0m0c1 tests the use of the API.
- Command: `swift package update FoundationModelsACP`, then `swift build`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass. (This task adds no behavior. The test is that the existing suite still passes on the new revision.)

## Subtasks

- [ ] Check that 34m4s52 is done and pushed.
- [ ] Update `Package.resolved`.
- [ ] Run `swift build` and `swift test`.
