---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0fjvz54j645066p03ddpyrz
  text: |-
    ### verify — done
    - evidence: dispatch run 32366296307 at e6ba4d4, against workflows origin/main 5f7e9a5 (contract commit f7b504f). Result: success. unit / Build & test: success. Integration (real agent subprocesses): success (15s run after a ~22-minute runner queue). unit / Integration (opt-in, real dependencies): skipped.
    - finding 1: the landed swift-ci.yaml made no input required, so our no-input call resolves. The shared integration job now declares `needs: test` internally.
    - finding 2: the skipped opt-in row is permanent for no-input callers — the `if:` gate on the shared integration job is unchanged. It does not disappear.
    - open decision (Will's): accept the cosmetic skipped row, or go fully repo-local for the unit job as Multitool and Router did. No correctness impact either way.
  timestamp: 2026-08-20T12:38:22.628774+00:00
position_column: done
position_ordinal: '8880'
title: Re-verify ci.yml after the shared swift-ci push lands
---
The workflows-06 session is finalizing swissarmyhammer/workflows swift-ci.yaml: selector inputs, LEGACY env-gate inputs, and a README that accepts the nested-package shape. As of 2026-08-20, origin/main there ends at 9b3f07e and the push has not landed.

When the push lands:
1. Make sure our `unit` job call to swift-ci.yaml@main still resolves and the run stays green.
2. See if the finalized workflow suppresses the "Integration (opt-in, real dependencies)" job when a caller passes no inputs. If it does not, the permanently skipped row stays in our runs — then decide with Will: pass a suppress input if one exists, or go fully repo-local as multitool did.

Context: this repo is compliant with the four family CI expectations (proof: CI run 32297216761 at commit e6ba4d4). The multitool session recorded the compliance. #ci