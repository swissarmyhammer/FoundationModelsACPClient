---
comments:
- actor: claude-code
  id: 01m0aq2h4w7spm995cc834d5r9
  text: |-
    Blocker: this task cannot compile against the wire package. The work did not start.

    Research results (implement step, 2026-08-18):

    1. The card tells us to implement `readTextFile` and `writeTextFile`, and to advertise `ClientCapabilities.fs`.
    2. The wire package `FoundationModelsACP` (branch main, revision 0da8ba7, the same in the local checkout and in `.build/checkouts`) does not have these items:
       - The `Client` protocol has only two members: `sessionUpdate` and `requestPermission`. Its documentation says: "v2 removed `fs/*` and `terminal/*` outright — stable v2 defines no standard client capability fields". See `Sources/FoundationModelsACP/Connection/Client.swift`.
       - The type `ClientCapabilities` has only the `meta` field. There is no `fs` field. See `Sources/FoundationModelsACP/Generated/Models.generated.swift`.
       - The types `ReadTextFileRequest` and `WriteTextFileRequest` do not exist.
       - The generated method table (`MethodTable.generated.swift`) has no `fs/*` route and no `terminal/*` route, in the stable table and in the unstable table. Thus no refusing default exists to test.
       - The vendored schema `Schema/acp-v2.json` has no `read_text_file` or `write_text_file` entry.
    3. The wire package made this decision on purpose. Its kanban history (task 01KYD58WPKKF4BAN3AKFZV61KY) records: "No `elicitation/*`, no `fs/*`/`terminal/*`" on the `Client` protocol.
    4. This client repo already records the same fact. `Sources/FoundationModelsACPClient/ACPClient.swift` says: "ACP stable v2 defines no standard client capability field, and this client implements no unstable extension."
    5. The premise of the card comes from `plan.md`, section "Capabilities: what a client owes the agent". That section says `ClientCapabilities` is `{ fs, session, terminal }`. This shape is the old v1 shape. It does not agree with the current wire package.

    Why this is a true conflict:

    - A TDD test that refers to `ReadTextFileRequest` or `ClientCapabilities.fs` cannot compile. A compile error is not a valid TDD red state.
    - A fix needs a change to the wire package, which is a different repository. That repository made the opposite decision and recorded it.
    - The implement rules forbid me to change the scope of the card or to make this decision myself.

    A person must decide one of these paths:

    - Path A: change the wire package `FoundationModelsACP` to add the `fs` capability, the two request types, and the two `Client` methods. Then this card becomes possible.
    - Path B: remove or rewrite the M5 milestone in `plan.md` and close this card, because ACP stable v2 has no client filesystem surface.

    I made no file change. The task stays in `doing` with this blocker.
  timestamp: 2026-08-18T15:15:39.804070+00:00
- actor: claude-code
  id: 01m0aq2nxmd3t23fy38j8f0qpr
  text: |-
    ### implement — stuck
    - evidence: 0 files changed. The wire package FoundationModelsACP (revision 0da8ba7) has no `ClientCapabilities.fs`, no `ReadTextFileRequest`/`WriteTextFileRequest`, no `fs/*` method routes, and no fs members on the `Client` protocol. The card requires code that cannot compile. See the blocker comment above for the full evidence.
    - next: a person must select Path A (add fs to the wire package) or Path B (remove M5 from plan.md and close this card).
  timestamp: 2026-08-18T15:15:44.692197+00:00
- actor: claude-code
  id: 01m0aq3f43w4t28x5rpvfbtc3a
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 0 files changed. The card requires `ClientCapabilities.fs`, `ReadTextFileRequest`, `WriteTextFileRequest`, and `fs/*` routes. The wire package FoundationModelsACP (rev 0da8ba7, ACP stable v2) removed that surface. Code for this card cannot compile.
    - This is a true conflict between the card (from plan.md, v1 shape) and the dependency. A person must select one path:
      - Path A: add the `fs` capability and the two Client methods to FoundationModelsACP.
      - Path B: remove or rewrite the M5 milestone in plan.md and close this card.
    - The finish loop skips this task. It stays out of `done`.
  timestamp: 2026-08-18T15:16:10.499442+00:00
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: doing
position_ordinal: '80'
title: 'M5 Filesystem capability: readTextFile and writeTextFile with confinement'
---
## What

`plan.md` -> **Capabilities: what a client *owes* the agent**.

Being an ACP `Client` is not only display. `ClientCapabilities.fs` gates `readTextFile` and `writeTextFile`, and every gated method has a **refusing default** -- so advertising the capability is a commitment to implement it. An agent editing code needs both, so this is v1.

This means **this package touches the user's files**, which requires a real policy, not a passthrough:

- **Confinement:** which roots are reachable. ACP's `session/new` carries `cwd` and `additionalDirectories`; those bound what the agent may ask for. Reject paths outside them rather than trusting the agent.
- **Path handling:** absolute paths, symlink escape, `..` traversal, and case-insensitive-filesystem collisions each need explicit handling. A confinement check that a symlink defeats is not a confinement check.
- **Consent:** decide whether writes prompt (via the M3 pending-request machinery) or are pre-authorized per session, and document which.
- **Encoding and size:** these are *text* file methods; decide behavior for non-UTF8 and very large files rather than reading unbounded data into memory.
- Advertise `fs.readTextFile` / `fs.writeTextFile` only once each is genuinely implemented.

## Acceptance Criteria

- [ ] `readTextFile` and `writeTextFile` implemented and advertised.
- [ ] Confinement derived from `cwd` + `additionalDirectories`; out-of-scope paths refused with a proper ACP error.
- [ ] Symlink escape and `..` traversal cannot leave the confined roots.
- [ ] Non-UTF8 and oversized files behave per a documented rule, never an unbounded read.
- [ ] Write consent model implemented and documented.

## Tests

- [ ] Read and write inside a confined root succeed and round-trip content exactly.
- [ ] A path outside the roots is refused -- asserted for absolute paths, `..` traversal, **and a symlink pointing outside**.
- [ ] Non-UTF8 content behaves per the documented rule.
- [ ] An oversized file does not read unbounded memory.
- [ ] With the capability unadvertised, the refusing default applies and the agent gets a clean error.

## Workflow

- Use `/tdd` -- write failing tests first, starting with the symlink-escape case.
