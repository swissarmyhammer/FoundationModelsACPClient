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
- actor: claude-code
  id: 01m0ara28ebc2dvzex5pfp7p1a
  text: |-
    ### commit — changed
    - evidence: f1d3700 feat(transport): add in-process pairing and stdio connect to an external agent
    - next: none
  timestamp: 2026-08-18T15:37:15.278075+00:00
- actor: claude-code
  id: 01m0arg55grtvfb0wtn70rvv7p
  text: |-
    ### review — findings
    - evidence: 3 findings — Sources/FoundationModelsACPClient/AgentProcess.swift:318, Tests/FoundationModelsACPClientTests/TransportTestSupport.swift:13, Tests/FoundationModelsACPClientTests/TransportTestSupport.swift:16
    - next: Obey each finding in the "## Review Findings (2026-08-18 10:37)" section. Then run the review again.

    step: review
    outcome: findings
    evidence: 3 findings — Sources/FoundationModelsACPClient/AgentProcess.swift:318, Tests/FoundationModelsACPClientTests/TransportTestSupport.swift:13, Tests/FoundationModelsACPClientTests/TransportTestSupport.swift:16
    task: ^nfbzx9w
  timestamp: 2026-08-18T15:40:34.864888+00:00
- actor: claude-code
  id: 01m0argpstq09ydfa2401fpg8d
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files (AgentProcess.swift, ProcessRegistry.swift, SwiftUIACPClient+Connect.swift, AgentProcessTests.swift, InProcessConnectionTests.swift, TransportTestSupport.swift)
    - test: green — swift test, 53 passed, 0 failures, 0 warnings
    - commit: f1d3700
    - review: findings — Sources/FoundationModelsACPClient/AgentProcess.swift:318, Tests/FoundationModelsACPClientTests/TransportTestSupport.swift:13, Tests/FoundationModelsACPClientTests/TransportTestSupport.swift:16
  timestamp: 2026-08-18T15:40:52.922840+00:00
- actor: claude-code
  id: 01m0armdqhwqc699nd9aspw69p
  text: |-
    Corrections for the 3 magic-number findings:

    - `Sources/FoundationModelsACPClient/AgentProcess.swift` — the expression `64 * 1024` put two literals into an operator chain, which the rule reports. The declaration now holds the one value `65536` directly, and the doc comment says "64 KiB". The declaration itself names the value, which the rule permits. A scan of the full file found no other cause: each other numeric literal is `0` or `1`, which the rule permits.
    - `Tests/FoundationModelsACPClientTests/TransportTestSupport.swift` — the literals `10` and `20` were function arguments to `.seconds(_:)` and `.milliseconds(_:)`, which the rule reports. Two new named constants, `limitSeconds` and `pollIntervalMilliseconds`, now hold the values, and the `Duration` declarations use the constants. A scan of the full file found no other cause: the only other numeric literal is the `0` in `kill(pid, 0)`, which the rule permits.

    All 3 items in "## Review Findings (2026-08-18 10:37)" are set to `- [x]` on the card. `swift test`: 53 tests, 0 failures, 0 warnings.
  timestamp: 2026-08-18T15:42:54.705868+00:00
- actor: claude-code
  id: 01m0armhf4jwayvztp5f804q8v
  text: |-
    step: implement
    outcome: changed
    evidence: 2 files — Sources/FoundationModelsACPClient/AgentProcess.swift, Tests/FoundationModelsACPClientTests/TransportTestSupport.swift; 3 of 3 findings corrected and set to [x]; swift test — 53 tests, 0 failures, 0 warnings
    task: ^nfbzx9w
  timestamp: 2026-08-18T15:42:58.532446+00:00
- actor: claude-code
  id: 01m0arp3d0wvd1nja49vggrnss
  text: |-
    ### test — green
    - evidence: swift build (clean rebuild) — 0 errors, 0 warnings. swift test — 53 tests passed, 0 failed, 0 skipped.
    - next: none. The build and test suite are clean.
  timestamp: 2026-08-18T15:43:49.664196+00:00
- actor: claude-code
  id: 01m0arpzc4szm7y5k6azvmybvw
  text: |-
    ### commit — changed
    - evidence: 0b1a97b fix(client): replace magic numbers with named constants
    - next: none
  timestamp: 2026-08-18T15:44:18.308646+00:00
- actor: claude-code
  id: 01m0arv6tp5xtycdzp2e0zdzky
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 0 confirmed, 0 refuted; all prior findings are checked
    - next: none — task moved to done
  timestamp: 2026-08-18T15:46:37.014084+00:00
- actor: claude-code
  id: 01m0arvnnknekhhge31gsjc3ds
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 2 files; 3 review findings corrected and checked
    - test: green — swift test, 53 passed, 0 failures, 0 warnings
    - commit: 0b1a97b
    - review: clean — 0 findings on HEAD~1..HEAD; task moved to done
  timestamp: 2026-08-18T15:46:52.211021+00:00
depends_on:
- 01KYD4DVT6HNNEWD1EK9J9A1R5
position_column: done
position_ordinal: '8580'
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

## Review Findings (2026-08-18 10:37)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Sources/FoundationModelsACPClient/AgentProcess.swift:318` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsACPClientTests/TransportTestSupport.swift:13` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsACPClientTests/TransportTestSupport.swift:16` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
