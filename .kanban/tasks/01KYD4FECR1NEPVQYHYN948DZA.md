---
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: todo
position_ordinal: '8580'
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
