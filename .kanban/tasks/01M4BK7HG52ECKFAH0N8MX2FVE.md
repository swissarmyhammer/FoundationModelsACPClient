---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4bnzym8dqm3erww8d4wjkzc
  text: |-
    Research:
    - ^a25yvy1 is on FoundationModelsACP origin/main: b2cec56 "fix(transport): end the peer stream when an InMemoryTransport reader stops". The old pin in Package.resolved is 163f7eb.
    - ConnectionModelTests has `@Suite(.timeLimit(.minutes(1)))`, so a hang gives a time-out after one minute. The helper `makeAgentConnection(over:)` makes a ScriptedStubAgent on the agent end.
    - `ConnectionCloseReason` is not Equatable. The test uses a fileprivate `isEndOfInput` property, the same pattern as the `ConnectionState.failure` extension in the file.
    - `ConnectionModel.disconnect()` doc comment names only the AgentProcess transport.
  timestamp: 2026-10-07T17:18:48.456485+00:00
- actor: claude-code
  id: 01m4bq7v0c5dty6zcvmxhbxn2c
  text: 'RED at the old pin 163f7eb: `swift test --filter ConnectionModelTests/disconnectEndsAnInProcessAgent` recorded "Time limit was exceeded: 60.000 seconds" at ConnectionModelTests.swift. Discovery: after the time-out issue, the test process does not exit. `AgentSideConnection.closed` does not stop for task cancellation, so Swift Testing waits for the test body after it records the issue. The run had to be stopped by hand. With output to a file, Swift Testing buffers its events; `script -q` gives a terminal so the events show. This hang applies only to the old pin; after the pin update the wait ends.'
  timestamp: 2026-10-07T17:40:35.468164+00:00
- actor: claude-code
  id: 01m4bqsnq0ypng231434s9rx56
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPClient/Model/ConnectionModel.swift (doc comment of disconnect()), Tests/FoundationModelsACPClientTests/Model/ConnectionModelTests.swift (test disconnectEndsAnInProcessAgent, and a fileprivate ConnectionCloseReason.isEndOfInput). `swift package update FoundationModelsACP` resolved FoundationModelsACP at b2cec56fc42cd5b1c4e25cfb8fe8773857bbbf65 (was 163f7ebbebc5c831319a618cf8ba7edde982e483). IntegrationTests/Package.resolved had its own older pin 27419fa (without ^a25yvy1); `swift package --package-path IntegrationTests update FoundationModelsACP` moved it to b2cec56 too. Both Package.resolved files are git-ignored.
    - RED: at 163f7eb, the new test recorded "Time limit was exceeded: 60.000 seconds". GREEN: at b2cec56, it passed in 0.001 seconds.
    - checks: `swift build` complete; `swift test` 569 tests in 49 suites passed; `swift test --filter ConnectionModelTests` 22 tests passed; `swift build --package-path IntegrationTests` and `swift build --build-tests --package-path IntegrationTests` complete. The only warning in the root package is the accepted MLX "missing creator for mutated node". The first `--build-tests` of the integration package compiled the mlx-swift Cmlx Metal kernels again and showed third-party `-Wc++17-extensions` warnings from IntegrationTests/.build/checkouts/mlx-swift; no warning comes from this package source.
    - next: the commit step must put the resolved revision b2cec56fc42cd5b1c4e25cfb8fe8773857bbbf65 in the commit message, as ^qcdqcm3 did. Then /review.
  timestamp: 2026-10-07T17:50:19.872963+00:00
- actor: claude-code
  id: 01m4bqxq6h3mmvx3cynjxyy6fh
  text: |-
    ### test — green
    - evidence: swift build: complete, 0 package warnings. swift test: 569 tests in 49 suites passed, 0 failed, 0 skipped. swift build --package-path IntegrationTests --build-tests: complete, 0 package warnings.
    - note: the only warning is "missing creator for mutated node" from the MLX bundle. It is accepted. No warnings came from .build/checkouts in these runs.
    - next: review or commit.
  timestamp: 2026-10-07T17:52:32.465837+00:00
- actor: claude-code
  id: 01m4bqyaj3eqfygmb7ask0vqw7
  text: |-
    ### commit — changed
    - evidence: 43dffd1 test(model): prove that disconnect() ends an in-process agent
    - next: review. The commit is local. No push.
  timestamp: 2026-10-07T17:52:52.291399+00:00
- actor: claude-code
  id: 01m4br6r4dm83jt3xt7n2ddwfy
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 9468005). 0 findings, 0 confirmed, 0 refuted. 7 validator runs attempted, 0 failed. 2 files reviewed. 8 .kanban files are not reviewed because .reviewignore excludes them.
    - note: the commit comment names sha 43dffd1. That sha was amended. The correct sha is 9468005.
    - next: none. The task is in done.
  timestamp: 2026-10-07T17:57:28.333030+00:00
- actor: claude-code
  id: 01m4br6z3w46qvxb80rkmsbb3f
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files; FoundationModelsACP resolves at b2cec56
    - test: green — swift test, 569 tests in 49 suites pass; IntegrationTests build passes
    - commit: 9468005 (the commit comment names 43dffd1, which was amended)
    - review: clean — zero findings; task is done
  timestamp: 2026-10-07T17:57:35.484933+00:00
depends_on:
- 01M4BK78NR5DCNP6WMAA25YVY1
position_column: done
position_ordinal: e180
title: 'Adopt the InMemoryTransport fix: pin FoundationModelsACP, and prove that disconnect() ends an in-process agent'
---
## What

Task ^a25yvy1 changes `InMemoryTransport.pair()` in FoundationModelsACP, so that an end that stops reading also ends the stream of the other end. This task brings that revision into this package, and proves the behavior from the model.

Do not start this task before ^a25yvy1 is done and its commit is on FoundationModelsACP `main`. Check this with `git -C ../FoundationModelsACP fetch origin main` and `git -C ../FoundationModelsACP log origin/main --oneline -20`.

1. Run `swift package update FoundationModelsACP`. `Package.resolved` is git-ignored here, so record the resolved revision in the commit message, as task ^qcdqcm3 did.
2. In `Tests/FoundationModelsACPClientTests/Model/ConnectionModelTests.swift`, add a test over `InMemoryTransport.pair()` with a real `AgentSideConnection` on the other end (a `ScriptedStubAgent`): after `await model.disconnect()`, `await agentConnection.closed` gives `.endOfInput`, and the test ends with no sleep. Before the pin, this test hangs (use the suite time limit so the failure is a time-out, not a stuck run).
3. Update the doc comment of `ConnectionModel.disconnect()` (`Sources/FoundationModelsACPClient/Model/ConnectionModel.swift`): an in-memory agent now sees the end of its input too, the same as an `AgentProcess`.

## Acceptance Criteria

- [x] `Package.resolved` names a FoundationModelsACP revision that contains ^a25yvy1.
- [x] After `disconnect()` over an in-memory pair, the agent connection closes with `.endOfInput`.
- [x] `swift build`, `swift test`, and `swift build --package-path IntegrationTests` pass, with no new warning.

## Tests

- `disconnectEndsAnInProcessAgent` in `Tests/FoundationModelsACPClientTests/Model/ConnectionModelTests.swift`. No sleeps.
- Command: `swift test --filter ConnectionModelTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [x] Check that ^a25yvy1 is on FoundationModelsACP `main`.
- [x] Write the failing test.
- [x] Update the pin, and update the doc comment of `disconnect()`.
