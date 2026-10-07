---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4bkpc3ctvq2std9jz2ep0ec
  text: |-
    ### finish — skipped (handed off)
    - The FoundationModelsACP session (foundationmodelsacp-36) is reachable again. On 2026-10-07 I sent it the full plan from this card.
    - This change belongs to the FoundationModelsACP repository, so this board does not implement it.
    - next: when FoundationModelsACP main has the fix, record the sha here, close this card, and run /finish 8mx2fve.
  timestamp: 2026-10-07T16:38:37.420723+00:00
- actor: claude-code
  id: 01m4bm652wysr815jhxy3awb1h
  text: |-
    ### finish — skipped (work in progress in FoundationModelsACP)
    - evidence: FoundationModelsACP origin/main is still 163f7eb. The working tree has uncommitted changes in Sources/FoundationModelsACP/Transport/InMemoryTransport.swift and Tests/FoundationModelsACPTests/InMemoryTransportTests.swift. These changes come from the session foundationmodelsacp-36.
    - This board does not start an implementer, because that agent would write over the work of that session.
    - next: when the fix is on FoundationModelsACP main, record the sha here and close this card. Then run /finish 8mx2fve.
  timestamp: 2026-10-07T16:47:14.524796+00:00
- actor: claude-code
  id: 01m4bmmargqkgd9j039ffnd286
  text: |-
    ### upstream — committed locally, not pushed
    - evidence: foundationmodelsacp-36 committed b2cec56fc42cd5b1c4e25cfb8fe8773857bbbf65 in FoundationModelsACP. swift test --filter InMemoryTransportTests: 8/8 pass. Full swift test: 447 tests in 43 suites and 128 tests in 16 suites pass, with zero warnings.
    - The push failed 2 times. GitHub gave "Internal Server Error". origin/main is still 163f7eb.
    - next: do not pin b2cec56 yet. When the sha is on main, close this card and run /finish 8mx2fve.
  timestamp: 2026-10-07T16:54:59.088319+00:00
- actor: claude-code
  id: 01m4bnw21tjzke8hybcgqhgfs7
  text: |-
    ### upstream — done
    - evidence: FoundationModelsACP origin/main is b2cec56fc42cd5b1c4e25cfb8fe8773857bbbf65. I checked it with git fetch. The push worked at 17:16:28Z (163f7eb..b2cec56). foundationmodelsacp-36 did the work, the tests and the push.
    - next: /finish 8mx2fve pins b2cec56.
  timestamp: 2026-10-07T17:16:40.890209+00:00
position_column: done
position_ordinal: e080
title: 'Upstream (FoundationModelsACP): when one end of an InMemoryTransport pair stops reading, end the stream of the other end'
---
## What

**This change is in the FoundationModelsACP package (sibling repository `swissarmyhammer/FoundationModelsACP`), not in this package.** The FoundationModelsACP session is not reachable, so this card holds the plan. Task "Adopt the InMemoryTransport fix" on this board depends on it.

AgentViewKit found at client 36f3249 / FoundationModelsACP 163f7eb: `ConnectionModel.disconnect()` calls `ClientSideConnection.close()`. Over an `AgentProcess` transport, the agent stops. Over an `InMemoryTransport.pair()`, the in-process `AgentSideConnection` stays alive, because its `bytes` stream never ends. The kit added a wrapper transport to work around this.

The cause (FoundationModelsACP `main` 163f7eb):

- `Connection.close()` (`Sources/FoundationModelsACP/Connection/Connection.swift:576`) calls `shutDown(reason: .closedLocally)`, which cancels `readTask` (line 1175). It does not close the transport: the `ACPTransport` protocol (`Sources/FoundationModelsACP/Transport/NDJSONCodec.swift:39`) has only `bytes` and `write(_:)`.
- The cancel stops the read of `transport.bytes`. The line reader in `NDJSONCodec` (line 191) cancels its inner task on termination, so the iterator of `transport.bytes` ends with `.cancelled`.
- `AgentProcess` and `SubprocessTransport` (line 104) react to that end in `onTermination` and tear the process down. `InMemoryTransport.pair()` (`Sources/FoundationModelsACP/Transport/InMemoryTransport.swift:30`) sets no `onTermination`, so the outgoing direction of that end stays open. The `bytes` of the peer end never finishes.

Change (one file):

1. In `InMemoryTransport.pair()`, after the two streams are made, set:
   - `firstContinuation.onTermination = { termination in if case .cancelled = termination { secondContinuation.finish() } }`
   - `secondContinuation.onTermination = { termination in if case .cancelled = termination { firstContinuation.finish() } }`

   Then, when the reader of one end stops (the stream is cancelled, or the last reference is dropped), the outgoing direction of that end finishes, and the peer reads EOF. This mirrors a pipe: a process that stops reading and exits closes its write end too.
2. React only to `.cancelled`, not to `.finished`. A `.finished` end means that the peer closed its outgoing direction (a half-close). The documented half-close semantics must stay: the opposite direction stays open until its own end closes.
3. Update the doc comment of `InMemoryTransport` and of `pair()`: half-close by `close()` stays, and a reader that stops now also closes its own outgoing direction.

Do not add `close()` to `ACPTransport`. That is a wider protocol change, and the `onTermination` route is the one that `AgentProcess` and `SubprocessTransport` already use.

## Acceptance Criteria

- [ ] When the reader of end A stops (the task that iterates `A.bytes` is cancelled), `B.bytes` finishes.
- [ ] `A.close()` still finishes only `B.bytes`, and `A.bytes` stays open (half-close).
- [ ] When `B.bytes` finishes normally because B closed, A's outgoing direction stays open.
- [ ] A `ClientSideConnection` and an `AgentSideConnection` over one pair: after `client.close()`, `agent.closed` gives `.endOfInput`.
- [ ] Each existing test in FoundationModelsACP passes.

## Tests

- In FoundationModelsACP, add to `Tests/FoundationModelsACPTests/InMemoryTransportTests.swift`. No sleeps; wait on `closed` and on stream ends only.
  - `aReaderThatStopsEndsThePeerStream`
  - `closeIsStillAHalfClose`
  - `aNormalEndDoesNotCloseTheOtherDirection`
  - `closingTheClientConnectionEndsTheAgentConnection` (both connection roles over one pair)
- Command (in FoundationModelsACP): `swift test --filter InMemoryTransportTests`, then `swift test`.

## Workflow

Use /tdd — write failing tests first, then implement to make them pass.

## Subtasks

- [ ] Write the four failing tests in FoundationModelsACP.
- [ ] Set the `onTermination` handlers in `InMemoryTransport.pair()`.
- [ ] Update the doc comments.
- [ ] Push FoundationModelsACP `main` and record the commit on this card.
