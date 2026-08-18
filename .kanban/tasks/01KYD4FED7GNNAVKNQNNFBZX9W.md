---
comments:
- actor: claude-code
  id: 01m0aqpn086f64w70m7ybbnrsx
  text: |-
    Research complete. Findings:

    - The wire package gives these public surfaces: `InMemoryTransport.pair()`, `ACPTransport` (bytes + write), `ClientSideConnection`, `AgentSideConnection`, `Agent`, `Client`, `ACPLogger`.
    - `ClientSideConnection` has no public close callback. Thus this package must wrap the transport to see a disconnect. The wrapper sends the bytes through and gives one signal when the stream stops.
    - The wire package has `SubprocessTransport`, but it does not spawn in a process group and it does not do a group kill. The family pattern for this is `StdioServerProcess` and `ProcessRegistry` in FoundationModelsMCP. Those symbols are internal to that package. This package cannot import them. Thus this package will contain its own copy of the pattern: posix_spawn with POSIX_SPAWN_SETPGROUP, killpg plus waitpid on teardown, a pid registry, and an atexit sweep.
    - The wire package `ByteReader` and `fullWrite` are internal. This package will contain its own read thread and full-write loop with the same shape.
    - Plan for new code:
      1. `ProcessRegistry.swift` (internal): pid set behind a Mutex, atexit sweep, honest SIGKILL/crash limitation note.
      2. `AgentProcess.swift` (public): spawns one agent binary in its own process group, gives an `ACPTransport` on its stdio, does a group kill and a reap on teardown, on stream teardown, and on EOF. Respawn policy: no automatic respawn. The host must make a new `AgentProcess` and connect again.
      3. `SwiftUIACPClient+Connect.swift`: `connect(over:logger:)` makes a `ClientSideConnection`, sets `connectionState` to `.connected`, and sets it to `.disconnected` when the transport stops.
    - Test plan: stub `Agent` over `InMemoryTransport.pair()` for the in-process full session. A /bin/sh script speaks canned ACP v2 NDJSON for the foreign-agent stdio test (wire shapes taken from the wire package golden fixture). Kill, no-stray-pid, and process-group-child tests assert with kill(pid, 0) and ESRCH.
    - Note: the client request ids are monotonic from 1, so the canned script can reply with fixed ids 1, 2, 3.
  timestamp: 2026-08-18T15:26:39.112279+00:00
- actor: claude-code
  id: 01m0ar6f9aykbn3mwbg9wywb6f
  text: |-
    Implementation complete, with TDD. RED: the seven new tests failed to compile because `connect(over:)` and `AgentProcess` did not exist. GREEN: three new source files make them pass. REFACTOR: shared test helpers removed the copied blocks; the suite stayed green.

    New source files:
    - `Sources/FoundationModelsACPClient/ProcessRegistry.swift` — internal pid registry with the family's `atexit` sweep and the honest SIGKILL/crash limitation note.
    - `Sources/FoundationModelsACPClient/AgentProcess.swift` — public. Spawns the agent binary with `posix_spawn` and `POSIX_SPAWN_SETPGROUP`, vends an `ACPTransport` on its stdio, sets `F_SETNOSIGPIPE` on the stdin pipe, and does `killpg` plus `waitpid` on each teardown path: `shutdown()`, stream teardown, EOF (agent death — this path reaps the zombie), and owner `deinit`. Respawn policy documented: no automatic respawn; the host makes a new `AgentProcess` and connects again.
    - `Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift` — public `connect(over:logger:)`. Wraps the transport in `DisconnectObservingTransport`, which forwards the bytes and fires a one-shot signal when the stream stops in either direction; the signal sets `connectionState = .disconnected` on the main actor.

    New test files:
    - `Tests/.../InProcessConnectionTests.swift` — full session over `InMemoryTransport.pair()` against an `Agent`-conforming stub; host-close disconnect.
    - `Tests/.../AgentProcessTests.swift` — full session over stdio against a /bin/sh foreign agent; kill surfaces `.disconnected` and reaps; no stray pid after close (assert by pid and ESRCH); process-group child cleanup; relative-command refusal.
    - `Tests/.../TransportTestSupport.swift` — deadline-bounded helpers, so no test can hang.

    Result: `swift test` — 53 tests, 0 failures, 0 warnings. Note for the next agent: the foreign agent replies with fixed ids 1, 2, 3 because the client's request ids are monotonic from 1; if a test adds a request before `initialize`, the script must change.
  timestamp: 2026-08-18T15:35:17.546620+00:00
- actor: claude-code
  id: 01m0ar6p0nrny3xp3pnj9q2hc1
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPClient/AgentProcess.swift, Sources/FoundationModelsACPClient/ProcessRegistry.swift, Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift, Tests/FoundationModelsACPClientTests/AgentProcessTests.swift, Tests/FoundationModelsACPClientTests/InProcessConnectionTests.swift, Tests/FoundationModelsACPClientTests/TransportTestSupport.swift. `swift test`: 53 tests, 0 failures, 0 warnings.
    - next: /review
  timestamp: 2026-08-18T15:35:24.437730+00:00
- actor: claude-code
  id: 01m0ar8n34gqweqnp3sq4jy1ve
  text: |-
    ### test — green
    - evidence: swift build (clean rebuild) — 0 warnings, 0 errors; swift test — 53 passed, 0 failed, 0 skipped
    - next: none. The build and test suite are clean.
  timestamp: 2026-08-18T15:36:29.028143+00:00
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: doing
position_ordinal: '8180'
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

- [x] In-process pairing works end to end against a `FoundationModelsACPAgent`-shaped stub.
- [x] stdio transport connects to an external agent binary.
- [x] A spawned agent is group-terminated and reaped on teardown and on connection loss.
- [x] Agent death surfaces as observable connection state, not a hang.
- [x] Respawn policy implemented and documented; no silent restart into empty state.
- [x] The `SIGKILL`/crash limitation is documented as plainly as siblings document theirs.

## Tests

- [x] Full session over `InMemoryTransport.pair()`: initialize, `session/new`, prompt, updates, stop.
- [x] Full session over stdio against a **foreign** ACP agent binary -- the test that proves the "knows nothing about our runtime" claim is real rather than aspirational.
- [x] Killing the agent process surfaces disconnected state promptly (no hang).
- [x] A spawned agent leaves no stray pid afterward -- assert by pid.
- [x] An agent that spawns a child has that child cleaned up too (process-group behavior).

## Workflow

- Use `/tdd` -- write failing tests first.
