---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6gzyfyzcwxnmjxz6w52rp9n
  text: |-
    Ready for review, 2026-11-03. Not committed. Root `swift test`: 760 tests pass (14 new in SubagentDerivedViewTests). Review (review working): clean, 0 findings.

    Public API (SessionModel+Views.swift): SessionPathEntry (sessionId, title, path, workState, pendingRequestCount, needsAttention; Hashable, Sendable, Identifiable). On SessionModel: displayTitle (child title, else sessionInfo title, else session id), pendingRequestCount (own only), needsAttention (own requires_action or own pending request or any child needsAttention; false when closed), pathEntry, ancestors (root first), siblings (parent.children, or the open root sessions for a root), descendants (depth first, announce order, computed). One rule at every level; tests run at depth 2 and 4. No selected-session state in ConnectionModel. A root session reads its siblings through a weak owner link set by ConnectionModel.

    Note for card 4: replayed content raises no needsAttention because a replayed child is unconfirmed (workState unknown) and a replay makes no pending request. The wire gap (history snapshot state kept) now has ACP card 01M6GZRBRBGZHYHWJ00YRHVMFB (shortid yrhvmfb): the engine gets a replay boundary call. Card 4 needs that card if it must show unknown after a current snapshot with no state.
  timestamp: 2026-11-03T15:20:22.239300+00:00
depends_on:
- 01M6GH6FH41C6VSFC3QRT8H1FS
position_column: todo
position_ordinal: '8280'
title: 'Sub-agent sessions 3/4: derived views (ancestors, siblings, descendants, needsAttention)'
---
## What
Part 3 of 4 of the split of card ^rt8h1fs. Part 1 (tree and routing) comes first. This card adds computed values for AgentViewKit (a breadcrumb bar with a dropdown at each crumb, and a jump-to-sub-session command). The views read ready-to-show values and build nothing.

Rule of the model (user decision, 2026-11-03): it is parent and child all the way down. Every session is the same kind of thing. Depth is not a case, and no depth is a limit. Each value below follows ONE rule at every level. A test chain of three sessions is only a test size.

No wire dependency. For tests of removal (`isClosed`), this card uses the flag from part 2. If part 2 is not done, test removal with a parent close from part 1 and add the `isClosed` checks when part 2 lands.

Requirements:
1. `SessionModel.ancestors`: the chain from the root to the parent of this session, root first. Each element is one crumb.
2. `SessionModel.siblings` (or `parent.children`): the choices of one crumb dropdown, in announce order. The root level lists the root sessions of the connection.
3. `SessionModel.descendants`: a flat list of all sub-sessions below this session, depth first, in announce order. Computed from `children`; it keeps no copy.
4. `SessionPathEntry`: a small value type. Fields: session id, `title`, `path` (titles from the root, as an array), `workState`, `pendingRequestCount`, `needsAttention`. `Hashable`, `Sendable`, cheap to compare. `ancestors`, `siblings` and `descendants` give these entries (or a view of them).
5. `SessionModel.needsAttention`: true when this session or any descendant is `requires_action` or has a pending request. Computed, so every view gets the same answer. A question deep in the tree shows on every ancestor.
6. A session that failed to restore (unknown, from part 4) counts in `children`, `descendants` and `ancestors`. Its `needsAttention` is false unless the user must act.
7. Which session a window shows is VIEW state in AgentViewKit. Do NOT put a "selected session" in `ConnectionModel`.

## Acceptance Criteria
- [ ] `ancestors` is root first, and each element is the parent of the next, for a test chain of nested sessions (three is enough for the test).
- [ ] `siblings` order equals announce order; the root level lists the root sessions.
- [ ] `descendants` is depth first in announce order, for a test tree where each session has two children.
- [ ] A child added or removed changes `descendants`.
- [ ] The `path` of each `descendants` entry equals the `ancestors` titles of that session plus its own title.
- [ ] Each entry of `ancestors`, `siblings` and `descendants` carries the right `path`, `workState`, `pendingRequestCount` and `needsAttention`.
- [ ] `needsAttention` rises on every ancestor when a nested descendant has a pending request, and falls when the request is answered.
- [ ] The same rule holds at every level: a test at one depth gives the same result at another depth.
- [ ] A removed child is not in `children` or `descendants` (and reports `isClosed` once part 2 is done).
- [ ] Observation test: a change of `workState`, `children` or a pending request fires the `@Observable` tracking of the derived value.

## Tests
- [ ] `Tests/FoundationModelsACPClientTests/SubagentDerivedViewTests.swift`: all items above.
- [ ] Run `swift test --filter SubagentDerivedViewTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first. #subagents