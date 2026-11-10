---
assignees:
- claude-code
depends_on:
- 01M7302MHW9G50K9NMMQSGVQNH
position_column: todo
position_ordinal: '8380'
title: 'ACPC-4: move _mcp_server_status and _mail_delivery_paused onto the extension point'
---
## What
Prove the session part of ACPC-4 with the two built-in `_` session updates. After this task, `SessionModel` has no hard-coded `_` update branch.

Make these changes:
- [ ] New `Sources/FoundationModelsACPClient/Model/MCPServerStatusExtension.swift`: a `ClientModelExtension` whose session state holds the `[MCPServerItem]` list. It takes `_mcp_server_status` (with `MCPServerStatusUpdate.decode`) and seeds the list from the `session/new` / `session/resume` request in `didStartSession` (the logic that `SessionModel` has today for `mcpServers`).
- [ ] New `Sources/FoundationModelsACPClient/Model/MailDeliveryPauseExtension.swift`: a `ClientModelExtension` whose session state holds `MailDeliveryPause?`. It takes `_mail_delivery_paused`. It clears the pause at a `user_message` or `user_message_chunk` update. Thus the extension must see these updates and give `false` for them, so they still go to the engine.
- [ ] `ConnectionModel` registers the two built-in extensions in its initializer, before each host extension.
- [ ] `Model/SessionModel.swift`: remove the two branches from `engineChange(folding:)`. `public var mcpServers` and `public var mailDeliveryPause` stay as public read-only properties that read the extension state, so no host code changes. Observation of them must still report each change.
- [ ] Update the doc comments of `SessionModel` that name the two updates.

## Acceptance Criteria
- [ ] `engineChange(folding:)` has no `MCPServerStatusUpdate` or `MailDeliveryPause` branch.
- [ ] The public API of `SessionModel.mcpServers` and `SessionModel.mailDeliveryPause` does not change.
- [ ] All existing tests pass with no change of their assertions.

## Tests
- [ ] `Tests/FoundationModelsACPClientTests/Model/SessionModelMCPServerStatusTests.swift` and `SessionModelMailPauseTests.swift` stay green with no change to the assertions. Add one test to each that observes the property (`ObservationWait.swift`) and asserts the change is reported.
- [ ] Run `swift test --filter "SessionModelMCPServerStatusTests|SessionModelMailPauseTests|ClientModelExtensionTests"` → all pass. Then `swift test` → all pass, and the `IntegrationTests` package (`swift test --package-path IntegrationTests`) → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1