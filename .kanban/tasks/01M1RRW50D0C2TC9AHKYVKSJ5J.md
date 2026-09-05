---
assignees:
- claude-code
position_column: todo
position_ordinal: a280
title: 'cli-plan.md §10: describe the authMethods arms row 6 now has'
---
## What

Discovered while implementing ^jz39et3.

`cli-plan.md` §10, in the paragraph on the sixth row of the check table, says
the row "does NOT yet read `authMethods`" and that card ^1qfgtye holds that
work. Both statements are stale. Commit 48bccae (^1qfgtye) made the row count
the `authMethods` elements the forgiving decode dropped, and ^jz39et3 made it
name an `authMethods` member that is not an array. The plan is the document a
reader trusts for the doctor's contract, so it must describe what the row does.

## Acceptance Criteria

- [ ] The §10 paragraph on row 6 states the three `authMethods` arms: elements
      dropped from an array are reported by count; a member that is not an
      array is named as that member; a `null` member is read as absent.
- [ ] The paragraph no longer names ^1qfgtye as open work.
- [ ] The text is in ASD-STE100 Simplified Technical English.

## Tests

- [ ] None. This is a documentation change; `swift test` and the integration
      suite stay green.