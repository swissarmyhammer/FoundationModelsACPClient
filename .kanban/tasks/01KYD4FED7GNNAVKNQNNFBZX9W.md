---
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: todo
position_ordinal: '8680'
title: 'M6 Transports: in-process pairing and stdio to an external agent'
---
## What

`plan.md` -> **Transports, and who owns the agent process**.

Two deployments, one client:

- **In-process** -- `InMemoryTransport.pair()` (public in `FoundationModelsACP`) wires this client to an agent in the same process. This is how our Mac app drives `FoundationModelsACPAgent`, and it is what keeps our UI on the same interface external clients use.
- **Out-of-process** -- stdio to an agent binary, ours or a third party's.

The out-of-process case means **this package may spawn and own the agent process**, carrying the obligations that recur throughout this family (see `FoundationModelsShelltool`'s `ProcessRegistry` and `FoundationModelsMCP`'s `StdioServerProcess`):

- process-group spawn, so the agent's own children are reachable;
- group termination and **reaping** on teardown and on connection loss;
- an `atexit`-style sweep as a backstop, with the limitation stated honestly -- no guarantee under `SIGKILL` or a crash;
- respawn policy: whether a died agent is restarted, and what happens to session state if so. Likely: surface the loss, never silently restart into an empty session.

Prefer reusing the family's existing pattern over inventing a third variant.

## Acceptance Criteria

- [ ] In-process pairing works end to end against a `FoundationModelsACPAgent`-shaped stub.
- [ ] stdio transport connects to an external agent binary.
- [ ] A spawned agent is group-terminated and reaped on teardown and on connection loss.
- [ ] Agent death surfaces as observable connection state, not a hang.
- [ ] Respawn policy implemented and documented; no silent restart into empty state.
- [ ] The `SIGKILL`/crash limitation is documented as plainly as siblings document theirs.

## Tests

- [ ] Full session over `InMemoryTransport.pair()`: initialize, `session/new`, prompt, updates, stop.
- [ ] Full session over stdio against a **foreign** ACP agent binary -- the test that proves the "knows nothing about our runtime" claim is real rather than aspirational.
- [ ] Killing the agent process surfaces disconnected state promptly (no hang).
- [ ] A spawned agent leaves no stray pid afterward -- assert by pid.
- [ ] An agent that spawns a child has that child cleaned up too (process-group behavior).

## Workflow

- Use `/tdd` -- write failing tests first.
