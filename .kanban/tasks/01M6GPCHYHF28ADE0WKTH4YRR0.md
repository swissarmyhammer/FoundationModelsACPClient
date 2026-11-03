---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6gzyj8cmj4rvbrfbvmd9gjt
  text: 'BLOCKED BY (other board, so not in depends_on): FoundationModelsACP card 01M6GZRBRBGZHYHWJ00YRHVMFB (shortid yrhvmfb): SessionMergeEngine gets a replay boundary call, so a current subagent_update that omits state or capabilities does not keep the history value. The client calls it when the resume response arrives (SessionModel.endReplay). The ACP session will message the commit id and the final call name. Until then, a child that gets a current snapshot with no state can show the history state as confirmed (see the card 2/4 comment).'
  timestamp: 2026-11-03T15:20:24.588890+00:00
- actor: claude-code
  id: 01m6h0ngtzfryd7rg5xadfhgpz
  text: |-
    Done, 2026-11-03. Root `swift test`: 772 tests pass (10 new in SubagentRestoreFailureTests). Review: clean. Wire pin: main at 558b6a0 (holds markReplayBoundary 11eb95b and SAH.RestoreFailure 2b0bf96).

    Decisions:
    - restoreFailure is set only from the explicit `_meta.sah.restoreFailure` (SAH.RestoreFailure.extract) of a subagent_update, in a replay or not. The model invents no failure. No timer: a child with no current snapshot is only unconfirmed (workState unknown, no capabilities, cancel and prompt refused), which is a legal state.
    - A later current snapshot with a known state clears it. A resume that keeps the child models clears it at the start (the agent announces it again if it still holds).
    - A failed child has state unknown, capabilities nil, so cancel() and prompt() throw SubagentSessionError.notPermitted. It is in children, descendants and ancestors. needsAttention is false for it: unknown is not requires_action and it has no pending request, so the user has nothing to act on. A view shows it as lost with the reason.
    - Descendants of a failed child: the agent announces each as unknown with its own reason (an ancestor was not restored); each one is a normal child. Same id on a second resume works.
    - Also in this work: SessionModel.endReplay calls markReplayBoundary() when the resume response succeeds, so a current snapshot that omits state does not show the history state.
  timestamp: 2026-11-03T15:32:56.799761+00:00
depends_on:
- 01M6GH6FH41C6VSFC3QRT8H1FS
- 01M6GPC4KAYTRB13E8SE6SRMMS
position_column: done
position_ordinal: ff9e80
title: 'Sub-agent sessions 4/4: child restore failure (unknown state and restoreFailure)'
---
## What
Part 4 of 4 of the split of card ^rt8h1fs. Part 1 (tree and routing) comes first. Part 2 (resume) is related: the missing-snapshot rule there uses the unknown mark from this card. Do part 2 first when you can.

WAITS FOR the wire cards on the FoundationModelsACP board (other board, so not in depends_on): re-vendor 01M6GJ8GX6C0YRHJW0W2ADAVTE, wire types 01M6GJ664BHY454C5NFPFCSP79 (the `_meta` reason).

User decision (2026-11-03): a child session that fails to restore is announced, not hidden. This REPLACES the old text that said a failed child is kept out of the tree. A failed child IS in the tree, as unknown.

Agent side (for the test script): `subagent_update` with `state: unknown`, `capabilities: null`, stable id, parent id, title, and a short reason in `_meta` (for example missing tool, model mismatch, record unreadable). Its replay ends with that announcement. The root still resumes.

Client work:
- The child model has `workState` unknown and an observable `restoreFailure` (short reason string, nil when fine).
- RFD meaning of `unknown`: lost observability while ACP stays connected. It is nonterminal. The client must not show stale activity as live.
- A view shows it as lost, with the reason, and offers no prompt or cancel (capabilities empty).
- It counts in `children`, `descendants` and `ancestors`. `needsAttention` is false for it unless the user must act (decide here and write the decision in a comment).
- Missing snapshot: if the resume response arrives while a child is still `.replaying` and the agent sent no snapshot, mark the child `unknown` with a `restoreFailure` reason. Do not wait for ever.
- Descendants of a failed child: follow the rule that the agent card writes (announce as unknown, or not announced). Read the comment on the agent card, then write the same rule here. Test both an announced and an unannounced descendant case if the rule allows both.

## Acceptance Criteria
- [ ] A recorded child with a missing tool: the root resumes, and the client sees the child as unknown with `restoreFailure` set to the reason.
- [ ] The failed child has no cancel capability; `cancel()` and `prompt()` are refused locally.
- [ ] The failed child is in `children`, `descendants` and `ancestors`.
- [ ] The failed child keeps the same id on a second resume.
- [ ] `restoreFailure` is nil for a healthy child, and clears when a later current snapshot restores it.
- [ ] A missing snapshot at the response marks the child unknown with a reason.
- [ ] Descendants of a failed child follow the written rule.
- [ ] Observation test: a change of `restoreFailure` fires the `@Observable` tracking.

## Tests
- [ ] `Tests/FoundationModelsACPClientTests/SubagentRestoreFailureTests.swift`: all items above.
- [ ] Run `swift test --filter SubagentRestoreFailureTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first. #subagents