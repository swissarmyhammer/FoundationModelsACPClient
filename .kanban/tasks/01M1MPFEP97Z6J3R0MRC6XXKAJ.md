---
assignees:
- claude-code
depends_on:
- 01M1MQG0S4YXS3CKAE34A9AX26
- 01M1MPBN1SK31BWC0FW1R0X01Y
position_column: todo
position_ordinal: '8980'
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