---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Fold the private replayFromStart test constants onto SessionModelFixtures.replayFromStart
---
## What
Task ^gs1cx8r added `SessionModelFixtures.replayFromStart` (`Tests/FoundationModelsACPClientTests/Model/SessionModelFixtures.swift`). Five test files still declare their own copy of the same value: `SessionModelStreamTests.swift`, `SessionModelFoldTests.swift`, `SessionModelNoticeTests.swift`, `SessionModelCompactionTests.swift` (each `private let replayFromStart: ReplayFrom = .start(ReplayFromStart())`), and `ConnectionModelSessionTests.swift` / `Telemetry/ReplaySpanTests.swift` (as `static let`).

## Acceptance Criteria
- [ ] Each copy is removed, and each use reads `SessionModelFixtures.replayFromStart`.
- [ ] `swift test` passes with no new warning.