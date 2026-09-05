---
assignees:
- claude-code
position_column: todo
position_ordinal: 9b80
title: Fold the two private runArguments builders onto the shared one
---
## What

`^tdx6edk` needed a `run` command-line builder that takes both a prompt and the
options of `cli-plan.md` §6.1, and no shared one existed. It extracted
`runArguments(prompt:options:script:)` into
`IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift`
and called it from `TimeoutTests`.

Two near-copies of that builder stand outside that change, each private to its
own suite:

- `RunCommandExitTests.runArguments(prompt:script:)`
- `StreamRulesTests.runArguments(options:script:agentArguments:)`

The duplication validator's rule for an index-backed row says the fix goes in
the changed code and the counterpart is a separate piece of work. This is that
piece of work.

The shared builder already covers the first one whole. The second one adds the
agent's own arguments after the script, and it fixes the prompt at
`streamPrompt`, so folding it needs `agentArguments` on the shared signature.

## Acceptance Criteria

- [ ] `Support/StubAgents.swift` holds one `runArguments` that covers every
      call site: an optional prompt, the §6.1 options, the script, and the
      agent's own arguments.
- [ ] `RunCommandExitTests` and `StreamRulesTests` each declare no builder of
      their own, and every call site reads the shared one.
- [ ] `swift test --package-path IntegrationTests` passes with no change to any
      assertion.

## Tests

- [ ] No new test. This is a refactor with an unchanged observable result, and
      the suites that already drive those command lines are the guard.
