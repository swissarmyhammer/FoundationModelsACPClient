---
position_column: todo
position_ordinal: '8180'
title: Localize the text of AuthFailure.Reason.message
---
## What
Request from AgentViewKit (task ^fh4y0d7 there). AgentViewKit now shows `AuthFailure.Reason.message` for each sign-in failure, with no kit text table, because the kit views bind directly to the client model. The client texts are not localized. Before this change, the kit had localized texts for the terminal failures (`String(localized:)`).

- [ ] Make the text of `AuthFailure.Reason.message` localizable (for example `String(localized:bundle:)` with a string catalog in the client package), for each reason: request, terminal, unsupported.
- [ ] Keep the English text the same as now, so current callers and tests do not change.

## Acceptance Criteria
- [ ] Each text of `AuthFailure.Reason.message` comes from a localizable string resource of the client package.

## Tests
- [ ] A test checks the English text of each reason.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.