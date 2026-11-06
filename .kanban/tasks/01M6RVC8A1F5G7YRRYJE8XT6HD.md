---
assignees:
- claude-code
position_column: done
position_ordinal: ffa580
title: Send the identity of the person at initialize (_meta["sah/actor"])
---
Step 2 of 5 of the person-identity work (Extras, ACPClient, ACPAgent, Kanban, KanbanViewKit). Requested by the swissarmyhammer-75 session.

Problem: a GraphQL tunnel call gets a GraphQLViewer with no person, so KanbanGraph writes each UI edit as the agent. The client runs as the person, so the client must send the identity one time, at initialize.

Scope (ACPClient only):
- Move the FoundationModelsExtras pin to commit dbbd53e (GraphQLActor, GraphQLActor.initializeMetaKey, metaValue(as:)).
- Add an injectable identity source: a protocol with a local-user implementation (the default) and an iCloud implementation (opt-in only, because CKContainer traps without the iCloud entitlement).
- ConnectionModel.initialize resolves the actor, merges it into the request _meta under "sah/actor" (keep the other keys; keep a "sah/actor" value of the caller), and keeps the resolved actor on the model.

Acceptance:
- [ ] The request that goes out has `_meta["sah/actor"]` with the correct value.
- [ ] The other _meta keys of the caller stay.
- [ ] A "sah/actor" value of the caller is not replaced.
- [ ] The iCloud fallback logic is tested through injected account-status and record-id closures. No test touches CKContainer.
- [ ] The package builds and all tests pass. Push to main, and send the commit to swissarmyhammer-75.

Rule: send a design to swissarmyhammer-75 first. Do not write code until that session accepts the design. #feature