---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1qtp97pz8btvx5mcwk8m3y1
  text: |-
    The shared builder this task asks for now exists. Task ^f1fz3bv added
    `agentCommandArguments(_:options:script:)` to
    `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift`,
    beside `runSubcommandName`, `probeSubcommandName`, `doctorSubcommandName` and
    `agentCommandSeparator`. `runArguments(prompt:options:script:)` already calls it,
    and `NoLeakedAgentTests.swift` calls it for `probe` and for `doctor`.

    So the work left here is narrower than the title says: fold the two PRIVATE
    copies onto it — `ProbeCommandTests.probeArguments(options:script:)` and
    `DoctorCommandTests.doctorArguments(options:script:)` — and delete them. The
    doctor copy reads `DoctorCommand.name` through `@testable import AcpClientCore`;
    `doctorSubcommandName` is the same text spelled in the support file, so that
    import may then be needed for the other names alone.
  timestamp: 2026-09-05T03:44:42.230524+00:00
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
