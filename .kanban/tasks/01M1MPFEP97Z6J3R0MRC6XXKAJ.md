---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1pry0q92ybn8gg4tzdmjb3d
  text: |-
    Picked up. Research notes before the first test.

    Seams that are already in place:
    - `AgentSession.openSession()` returns `(SessionId, AsyncStream<SessionUpdate>)` with the subscription live, so `TurnRunner.run()` opens the session itself. The card gives `TurnRunner` four inputs only (session, prompt, terminal, answerSink), so the session id never leaves `run()`.
    - `TerminalOutput.withSpinner(label) { lineUpdate in ... }` is the only drawing entry point. The spinner ends when the body returns, so the turn is read in two loops: one inside the spinner (up to the first answer chunk) and one after it (up to `idle`).
    - `IdleStateUpdate.stopReason` is `StopReason?`. `AcpClientExitCode.idleWithNoReason` already exists for the absent case.

    Wire facts checked in the generated sources:
    - `SessionUpdate` carries `agentMessageChunk(ContentChunk)`, `agentThoughtChunk(ContentChunk)`, `stateUpdate(StateUpdate)` with `.idle(IdleStateUpdate)`, and `toolCallUpdate(ToolCallUpdate)` whose `title` is a `PatchField<String>`.
    - `ContentChunk.content` is a `ContentBlock`; only `.text(TextContent)` carries answer text.

    Concurrency shape: the prompt and the update reading must run together, because the turn ends on `idle` and not on the prompt answer. `run()` uses a throwing task group with one child that sends the prompt and one that reads the stream; the first outcome cancels the group, and a prompt failure propagates instead of waiting for an `idle` that will never come.

    Discovery for a later card: `ScriptedStubAgent` sends its whole script BEFORE it answers `session/prompt`, so it cannot tell an implementation that ends on the prompt answer from one that ends on `idle`. This card adds a second stub in the test file that answers the prompt first and sends `idle` only when the test opens a gate. That is the discriminating test for the acceptance row.

    Second discovery: nothing will call `AgentSession.closeSession(_:)` after this card, because `TurnRunner` keeps the session id private and the `RunCommand` card (^k0e160t) does not mention closing. Not changed here, because the card does not ask for it.

    Constraint noticed: `ExitCodeTests` fails any line of code below `Sources/acp-client/` that names "exit" and a decimal number, outside `ExitCode.swift`.
  timestamp: 2026-09-04T17:54:44.073108+00:00
- actor: claude-code
  id: 01m1psmfyvm477v7gp1a19mf4d
  text: |-
    Implementation landed, by the red-green cycle.

    RED: the eight tests were written first against a `TurnRunner` whose `run()`
    opened the session, sent the prompt, and returned `.idleWithNoReason` at the
    acknowledgement. `swift test --filter TurnRunnerTests` reported 12 issues over
    7 tests. Each failure named the behaviour the card asks for.

    What did NOT work, so the next agent does not repeat it:

    1. First shape: a `SessionUpdateReader` class holding the `AsyncStream`
       iterator, so a loop inside the spinner and a loop after it could share it.
       The compiler refused twice. `cannot call mutating async function 'next()'
       on actor-isolated property 'iterator'` — a suspension inside `next()` would
       hold exclusive access to the stored property across an `await`. Copying the
       iterator out, advancing it and writing it back then gave `sending
       'advancing' risks causing data races`.
    2. `group.addTask { @MainActor in ... }` gave `pattern that the region-based
       isolation checker does not understand how to check. Please file a bug`. The
       answer is a plain `addTask` closure that `await`s the main-actor method; the
       hop is implicit and the checker follows it.
    3. The spinner body written inside a main-actor method is a main-actor,
       non-Sendable closure, and `withSpinner` sends it into Noora: `sending value
       of non-Sendable type ... risks causing data races`.

    The shape that works removes the shared iterator. The reading is ONE `for
    await` loop, and the spinner is a third child of the task group driven by an
    `AsyncStream<String>` of tool names. The reader yields each running tool name
    into that stream and ends the stream at the first answer chunk — which is
    where §8 stops the spinner — and again at the end of the turn, for a turn that
    carried no answer text. The spinner body is then one loop over a Sendable
    stream, capturing Sendable values only, so it sends cleanly.

    `spinnerLabel` lives in a file-level `TurnRunnerText` namespace and not on
    `TurnRunner`, because a static member of a main-actor type cannot be read from
    the spinner's own task.

    GREEN: `swift test` — 180 tests in 12 suites passed, zero failures and zero
    warnings.
  timestamp: 2026-09-04T18:07:00.571715+00:00
- actor: claude-code
  id: 01m1psmmb81acxyrka2d0emcrd
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/acp-client/TurnRunner.swift (new), Tests/FoundationModelsACPClientTests/TurnRunnerTests.swift (new), Tests/FoundationModelsACPClientTests/ScriptedStubAgent.swift (gated deferred script, `UpdateGate`, `GatedUpdates`). `swift test`: 180 tests in 12 suites passed, 0 failures, 0 warnings. Every acceptance row and every test row of the card has a test.
    - next: /review
  timestamp: 2026-09-04T18:07:05.064579+00:00
- actor: claude-code
  id: 01m1pt0gt4g4pedqk1xgp1ft1s
  text: |-
    ### review — clean
    - evidence: `review sha bf6f175~1..bf6f175` — 7 validators attempted, 0 findings, 0 confirmed, 0 refuted, 0 failed. 3 files reviewed (TurnRunner.swift, ScriptedStubAgent.swift, TurnRunnerTests.swift); 4 .kanban files excluded by .reviewignore.
    - judged: the three points the implementer recorded.
    - 1. Concurrency is sound, not only compiling. Nothing mutable crosses an isolation boundary. `toolNames` has exactly one consumer (the spinner child); `toolNameFeed` is a Sendable continuation yielded to from the main actor; `AsyncStream.Continuation.finish()` is idempotent, so the `defer` and the `.answerWritten` case cannot conflict. The spinner child captures only `output` and the stream, so its body stays a plain Sendable loop, which is what the shared-iterator error was pointing at.
    - 2. The gated deferred script does discriminate. In `theTurnEndsOnIdleAndNotOnThePromptAnswer` the stub answers `prompt` with an empty script, so the acknowledgement is on the wire first. A runner that ended on the acknowledgement would return before `answerGate.open()`, its reader child would be cancelled, `harness.answer` would stay empty, and `#expect(await eventually { !harness.answer.isEmpty })` would fail. The second assertion, `outcomes.elements.isEmpty`, fails on the same violation. The test cannot pass a runner that breaks the rule.
    - 3. The deferrals are acceptable, and one of the two stated risks does not exist. `AgentSession.closeSession(_:)` is unused in production, but this card builds `TurnRunner`, which holds no process and owns no exit path; ^0e160t (Wire RunCommand) owns that. The claimed hang at group exit does NOT occur: `run()` calls `group.cancelAll()` before it returns, and the wire's `Connection.request(...)` wraps its continuation in `withTaskCancellationHandler` whose `onCancel` runs `cancelOutbound(id:)`, which resumes the pending continuation with `CancellationError` and sends `$/cancel_request`. `close()`/`shutDown()` rejects every pending request with `ConnectionError.closed`, and `requestTimeout` is a further backstop. So the prompt child unblocks and the group drains. What remains for the --timeout card is only the agent that stays connected and sends nothing at all.
    - next: no rework. Task moved to done.
  timestamp: 2026-09-04T18:13:34.660564+00:00
- actor: claude-code
  id: 01m1pt1rcb2sd89b5hzzd224pj
  text: |-
    ### review — correction to the previous comment

    One statement in the previous comment is wrong, and two facts belong to the downstream cards. The verdict does not change.

    **Wrong:** I wrote that `requestTimeout` is "a further backstop". It is not. `ClientSideConnection.init` defaults `requestTimeout` to `nil`, and `Sources/FoundationModelsACPClient/SwiftUIACPClient+Connect.swift` builds the connection without passing one, so `makeTimeoutTask` returns `nil`. An in-flight `prompt` has exactly three exits: a peer response, task cancellation, or disconnect. There is no timer.

    **Still correct, and the reason the verdict stands:** the group-exit hang the implementer described does not occur. `run()` calls `group.cancelAll()` before it returns; `Connection.request(...)` wraps its continuation in `withTaskCancellationHandler`, whose `onCancel` runs `cancelOutbound(id:)`, which resumes the pending continuation with `CancellationError` and then sends `$/cancel_request`. `shutDown()` resumes every pending continuation with `ConnectionError.closed`. The wire package has a test for this in `DisconnectTests.swift`: it cancels a Task around an in-flight `request(method: "hang")`, asserts `error is CancellationError`, and asserts the peer receives `$/cancel_request` with the matching id.

    **For ^cx9a5xsfa / ^0jrcz (Ctrl-C, exit 4):** cancelling the Swift Task sends the JSON-RPC `$/cancel_request`, NOT the ACP `session/cancel`. The library never sends `session/cancel` on your behalf — `ClientSideConnection.sessionCancel(_:)` is an explicit call, and nothing in `Sources/` calls it. An agent that honors only `session/cancel` will keep generating after the local `await` unblocks. That card must call `sessionCancel` itself.

    **For ^czcz (--timeout, exit 124):** because there is no `requestTimeout`, an agent that stays connected and sends nothing leaves `run()` waiting with no time limit at all. That card owns the only limit there will be.

    **Note on the trace:** `FoundationModelsACP` resolves as a remote checkout pinned at `9ab9f649d7557e6d9315814d3e5f3d113b52de8f`, not the sibling working copy. `Connection.swift` is identical in both, so the sibling directory is safe to read for this code.
  timestamp: 2026-09-04T18:14:15.179212+00:00
- actor: claude-code
  id: 01m1pt306ad40yg7hqfqxzyb1x
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files (TurnRunner.swift new, TurnRunnerTests.swift new, ScriptedStubAgent.swift gains a gated deferred script)
    - test: green — 180 passed in 12 suites, 0 failures, 0 warnings
    - commit: bf6f175 feat(acp-client): stream the turn and detect end-of-turn on idle
    - review: clean — zero new findings, 7 validators, task moved to done

    The review verified the concurrency is sound rather than merely compiling, and that the gated test genuinely discriminates: a runner ending on the prompt acknowledgement would return before the answer gate opens, leaving the sink empty and failing two assertions.

    TWO FACTS FOR THE DOWNSTREAM CARDS, corrected by the review:
    - The claimed group-exit hang is NOT real. `run()` calls `group.cancelAll()`, and the wire package wraps each request continuation in `withTaskCancellationHandler` whose `onCancel` resumes it with `CancellationError()`. An agent that reports idle but never answers the prompt does not hang.
    - **There is no timeout backstop anywhere.** `ClientSideConnection.init` defaults `requestTimeout` to nil and `SwiftUIACPClient+Connect.swift` passes none. `--timeout` (^tdx6edk) owns the only limit there will ever be.
    - **Task cancellation sends `$/cancel_request`, NOT ACP `session/cancel`.** Nothing in Sources/ calls `ClientSideConnection.sessionCancel(_:)`. The Ctrl-C card (^ja5xsfa) must call it explicitly, or an agent honouring only the ACP-level cancel keeps generating after the local await unblocks.
  timestamp: 2026-09-04T18:14:55.946997+00:00
depends_on:
- 01M1MQG0S4YXS3CKAE34A9AX26
- 01M1MPBN1SK31BWC0FW1R0X01Y
position_column: done
position_ordinal: '9680'
title: Stream the answer to stdout and detect the end of the turn
---
## What

`cli-plan.md` §8. This is the heart of `run`, and it holds no process
handling: `AgentSession` gives the connection and the update stream, and
`RunCommand` owns the `AgentProcess`. That split is what makes this task
testable over `InMemoryTransport.pair()`.

Create `Sources/acp-client/TurnRunner.swift`:

- `@MainActor struct TurnRunner`. Its inputs are an `AgentSession`, the prompt
  text, a `TerminalOutput`, and an `answerSink: @Sendable (Data) -> Void` that
  production points at stdout and a test points at a buffer. It takes no
  command, no path and no process.
- `enum TurnOutcome: Sendable { case stopped(StopReason); case idleWithNoReason }`.
- `func run() async throws -> TurnOutcome`. It sends the prompt, then reads
  the update stream until the turn ends.

**The turn ends on `state_update` reporting `idle`, and not on the prompt
response.** In v2 `PromptResponse` holds only `meta`: it acknowledges that the
prompt was accepted, and it carries no stop reason.

**`IdleStateUpdate.stopReason` is optional.** The generated type says "Omitted
or `null` both mean the agent is not reporting a stop reason." So detect the
end of the turn on `.idle` **arriving**, never on a value being present, and
return `.idleWithNoReason` when the field is absent. `cli-plan.md` §9 gains a
row for it, in the documentation task: an `idle` with no stop reason is a
completed turn, and it exits 0.

While reading:

- write each `agent_message_chunk` text to `answerSink` and flush it at once;
- write nothing else to the sink: not a session id, not a stop reason, no
  trailing newline, and no colour, in a terminal and in a pipe alike;
- a **thought** chunk is not answer text and never reaches the sink;
- run the spinner from the prompt until the first chunk, and report the
  running tool name through the line-update callback the spinner hands back.

## Acceptance Criteria

- [ ] The sink holds exactly the concatenation of the answer chunks, byte for
      byte, with nothing added.
- [ ] The turn ends on the `idle` `state_update`, and not at the prompt
      acknowledgement.
- [ ] An `idle` that carries a stop reason gives `.stopped(reason)`; an `idle`
      with no reason gives `.idleWithNoReason`.
- [ ] A thought chunk reaches the container but never the sink.
- [ ] A chunk that arrives immediately after the prompt is not lost.
- [ ] The spinner runs from the prompt to the first chunk, and draws nothing
      when stderr is not a terminal.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/TurnRunnerTests.swift`,
      driving `TurnRunner` over `InMemoryTransport.pair()` with a stub agent
      that answers `newSession` and sends a scripted update list. One test per
      acceptance row above.
- [ ] One test scripts `end_turn`, one scripts `refusal`, one scripts
      `cancelled`, and one scripts an `idle` with no `stopReason`. Each
      asserts the `TurnOutcome`.
- [ ] One test scripts a thought chunk beside an answer chunk and asserts only
      the answer text reaches the sink.
- [ ] One test scripts a multi-byte UTF-8 answer split across two chunks and
      asserts the sink bytes equal the concatenation.
- [ ] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.