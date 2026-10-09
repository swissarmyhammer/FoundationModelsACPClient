---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4h81z7t79nhgnjs5hd8m9wf
  text: 'Research done. The rg scan finds direct plan.md references in README.md, Package.swift, AgentProcess.swift, AgentInvocation.swift, and cli-plan.md at lines 4, 5, 26, 34, 335, 391-392, 426 and 470 (the card named 313; the real line is 391). Milestone ids: "M6" in the unit and integration AgentProcessTests only. The auth decision is already in the ACPClient.advertisedCapabilities doc comment. The other plan decisions (wire-only dependency, no SwiftUI import, @MainActor models, projection not record, v2 only, render but never run terminals, no filesystem surface, coalescing, process ownership) are not all in other locations, so the README gets a short "Design decisions" section. PlanDocumentTests reads cli-plan.md sections 5, 6, 6.1, 9, 10 row 6, 13.1 and 15; the edits do not touch those statements.'
  timestamp: 2026-10-09T21:10:41.146052+00:00
- actor: claude-code
  id: 01m4h92jd9gs56zctygpb6gdkn
  text: 'Implementation landed. plan.md is deleted (the deletion is not staged). Each reference now gives its reason directly: cli-plan.md opening, §2, §10 row 3 paragraph, §11, §12 and §13; Package.swift dependency comment; AgentProcess.swift file header; AgentInvocation.missingAgentCommand doc comment; "M6" removed from the unit and integration AgentProcessTests (also from the integration @Suite display name). README.md "Documentation" section is now "Design decisions": wire-only dependency, no SwiftUI import, @MainActor models, projection not record, v2 only, display terminals rendered not driven (no fs and no terminal methods), chunk coalescing, and process ownership. The auth decision already lives in the ACPClient.advertisedCapabilities doc comment, so cli-plan.md §13 now points there. cli-plan §10 now names the ACP stdio transport MUST instead of the agent package plan.md. Both rg acceptance scans find nothing. swift build: no warning in project sources (the only warnings come from the mlx-swift checkout). swift test: 594 tests in 52 suites passed. swift test --package-path IntegrationTests: 103 tests in 14 suites passed.'
  timestamp: 2026-10-09T21:28:29.353452+00:00
- actor: claude-code
  id: 01m4h92mejsaywnxq1se2mea3z
  text: |-
    ### implement — changed
    - evidence: 8 files — plan.md (deleted), cli-plan.md, README.md, Package.swift, Sources/FoundationModelsACPClient/AgentProcess.swift, Sources/AcpClientCore/AgentInvocation.swift, Tests/FoundationModelsACPClientTests/AgentProcessTests.swift, IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentProcessTests.swift; swift test 594 passed, integration 103 passed
    - next: /review
  timestamp: 2026-10-09T21:28:31.442462+00:00
- actor: claude-code
  id: 01m4h97vyk0s5fa0ejjpv5h7s1
  text: |-
    ### test — green
    - evidence: swift test (root) - 594 tests in 52 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests - 103 tests in 14 suites passed, 0 failed, 0 skipped.
    - note: One build line, "missing creator for mutated node ... mlx-swift_Cmlx.bundle", comes from the SwiftPM build of the mlx-swift dependency. It names no project file.
    - next: review
  timestamp: 2026-10-09T21:31:22.963457+00:00
- actor: claude-code
  id: 01m4h9pe9yvae84sks9jhgze4x
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD. 0 findings, 0 confirmed, 0 refuted. 7 validator runs, 0 failed. The validators reviewed 5 files. No validator applies to README.md, cli-plan.md and plan.md. A .reviewignore rule excludes 4 .kanban files.
    - next: none. The task moved to done.
  timestamp: 2026-10-09T21:39:20.510060+00:00
- actor: claude-code
  id: 01m4h9pntm0vf1kf89swctts8e
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files (plan.md deleted)
    - test: green — swift test 594 passed; IntegrationTests 103 passed
    - commit: 9236497
    - review: clean — 0 findings
  timestamp: 2026-10-09T21:39:28.212943+00:00
position_column: done
position_ordinal: e780
title: Remove plan.md and the references to it
---
The plan is old. The work is past the plan. Delete `plan.md`. Then make each text that refers to `plan.md` stand alone. A comment must give the reason directly. A comment must not point to a deleted file.

## Scope
- Remove only `plan.md`.
- Keep `cli-plan.md`. Keep its `§` section references. Keep `PlanDocumentTests.swift`, because it reads `cli-plan.md` and `README.md`, not `plan.md`.
- "Plan" in the ACP plan feature (`PlanTranscriptEntry`, plan updates, plan ids) is not a reference to `plan.md`. Do not change it.

## Known references (found on 2026-10-09)
Direct references to `plan.md`:
- `README.md:79` — a link to `plan.md`.
- `Package.swift:41` — `(plan.md, "a client, not *our* client")`.
- `Sources/FoundationModelsACPClient/AgentProcess.swift:2` — `(plan.md, "Transports, and who owns the agent process")`.
- `Sources/AcpClientCore/AgentInvocation.swift:63` — "the no-knowledge-of-our-runtime claim of `plan.md`".
- `cli-plan.md` — lines 4, 5, 26, 34, 313 and 335 (and possibly more) cite `plan.md`. `cli-plan.md` stays, so each of these citations must stand alone.

Indirect references (the milestone ids M0 to M7 of `plan.md`):
- `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentProcessTests.swift:7` and `:75` — "M6".
- `Tests/FoundationModelsACPClientTests/AgentProcessTests.swift:5` — "M6".

## Steps
1. Read `plan.md`. For each reference above, find the plan text that it points to.
2. Change each reference so that it stands alone. Write the rule or the reason directly at that location, in one or two short sentences. Remove the file name, the section name and the milestone id.
3. If the plan records an important decision that is not recorded in a different location, keep it as short text in the README or in the code comment at the related location.
4. Scan all comments and doc comments in `Sources`, `Tests`, `IntegrationTests`, `Package.swift`, `README.md` and `cli-plan.md` for other indirect references to `plan.md`. Examples: "the plan says", "see the plan", a milestone id, a quoted section title of `plan.md`. Make each one stand alone. Use the scope rules above to ignore `cli-plan.md` references and the ACP plan feature.
5. Delete `plan.md`.

## Acceptance criteria
- [x] `plan.md` does not exist.
- [x] `rg -n "(^|[^-])plan\.md" --glob '!.kanban/**'` finds nothing. (This pattern does not match `cli-plan.md`.)
- [x] `rg -n "\bM[0-7]\b" --glob '!.kanban/**'` finds no milestone id of `plan.md`.
- [x] No comment refers to `plan.md` indirectly. Each changed comment gives its reason directly.
- [x] Important decisions from the plan that are not in other locations are in the README or in the related code comments.
- [x] `cli-plan.md` still exists, and `PlanDocumentTests` still passes.
- [x] The build passes.
- [x] All tests pass.

## Note
FoundationModelsACP has a new task to connect `PendingPromptCorrelator` to `ClientSideConnection`. It also has a new client cancel helper: on `session/cancel`, it answers a pending `session/request_permission` with `cancelled`. These changes can change how this package uses the connection at a later time. Do not use the old plan text to describe that behavior.