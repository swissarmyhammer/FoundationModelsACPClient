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
- actor: claude-code
  id: 01m1rns5a5b263bdpe286v3xe6
  text: |-
    Picked up. Research result:

    The tree holds FOUR private builders, not two. The two the card names are still there, and the two the earlier comment names are there as well:

    - `RunCommandExitTests.runArguments(prompt:script:)` (7 call sites)
    - `StreamRulesTests.runArguments(options:script:agentArguments:)` (9 call sites; the prompt is fixed at the file-private `streamPrompt`, and one call site passes `agentArguments`)
    - `ProbeCommandTests.probeArguments(options:script:)` (5 call sites)
    - `DoctorCommandTests.doctorArguments(options:script:)` (1 call site; it reads `DoctorCommand.name` through `@testable import AcpClientCore`)

    The shared builders in `Support/StubAgents.swift` are `agentCommandArguments(_:options:script:)` and `runArguments(prompt:options:script:)`. Neither takes the agent's own arguments, so the fold needs an `agentArguments` parameter. It goes on `agentCommandArguments`, which is the one place that spells the line grammar, and `runArguments` passes it through.

    `TimeoutTests`, `InterruptTests` and `NoLeakedAgentTests` already call the shared builders and need no change.

    Plan: extend the two shared builders, delete the four private ones, and point every call site at the shared one. No assertion changes. The guard is the four suites themselves in `IntegrationTests`.
  timestamp: 2026-09-05T11:38:08.069837+00:00
- actor: claude-code
  id: 01m1rp21v1d4w3heq4rmm5avet
  text: |-
    ### implement — changed

    What changed:

    - `Support/StubAgents.swift`: `agentCommandArguments(_:options:script:agentArguments:)` takes the agent's own arguments after the script, with `[]` as the default. `runArguments(prompt:options:script:agentArguments:)` passes them through. The line grammar stays in the one place.
    - `RunCommandExitTests.swift`: the private `runArguments(prompt:script:)` is deleted. Its 7 call sites read the shared `runArguments`.
    - `StreamRulesTests.swift`: the private `runArguments(options:script:agentArguments:)` is deleted. Its 9 call sites read the shared `runArguments` with `prompt: streamPrompt`, and the one that passes agent arguments reads `agentArguments:`.
    - `ProbeCommandTests.swift`: the private `probeArguments(options:script:)` is deleted. Its 5 call sites read `agentCommandArguments(probeSubcommandName, ...)`.
    - `DoctorCommandTests.swift`: the private `doctorArguments(options:script:)` is deleted. Its 1 call site reads `agentCommandArguments(doctorSubcommandName, ...)`. The `@testable import AcpClientCore` stays, because the file reads `AgentCommandDoctor` names and `DoctorCommand.name` at two sites that build no stub-agent line.

    No assertion changed. The two sites that name a missing command or no agent at all (`["run", prompt, "--", missingCommand]`, `[DoctorCommand.name]`) build no stub-agent line, so they are outside the fold.

    Counterfactual: after the four private builders were deleted and before the call sites moved, `swift build --package-path IntegrationTests --build-tests` failed with `type 'RunCommandExitTests' has no member 'runArguments'` at the 7 call sites of that file (the compiler stopped there). That shows the call sites depended on the deleted copies. After the call sites moved, the same build passed with no warning.

    Guard: this is a refactor with no observable change, so the guard is the four suites that drive those command lines — `acp-client run exits`, `acp-client stream rules`, `acp-client probe reports`, `acp-client doctor reports and verdicts` — plus `NoLeakedAgentTests`, `TimeoutTests` and `InterruptTests`, which read the shared builders already.

    Callers checked after the signature change (each one compiles in the build above): `runArguments` — TimeoutTests (4), InterruptTests (2), NoLeakedAgentTests (2), RunCommandExitTests (7), StreamRulesTests (9). `agentCommandArguments` — `runArguments`, NoLeakedAgentTests (2), ProbeCommandTests (5), DoctorCommandTests (1).

    - evidence: 5 files — IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/Support/StubAgents.swift, RunCommandExitTests.swift, StreamRulesTests.swift, ProbeCommandTests.swift, DoctorCommandTests.swift. `swift test`: 223 tests in 19 suites passed, exit 0. `swift test --package-path IntegrationTests`: 77 tests in 12 suites passed, exit 0. No warning, no skipped test, no failure in either run.
    - next: /review
  timestamp: 2026-09-05T11:42:59.425219+00:00
- actor: claude-code
  id: 01m1rp89yyhfknwg4azmta98t5
  text: |-
    ### test — green

    - Command: `swift test` (root). Result: 223 tests in 19 suites. All tests passed. No warning. No skipped test.
    - Command: `swift test --package-path IntegrationTests` (nested). Result: 77 tests in 12 suites. All tests passed. No warning. No skipped test.
    - Before each run: `swift package clean` then `swift build --build-tests`. Both builds gave zero compiler warnings. (One dependency-resolver line said "skipping cache due to an error: The file maintenance.lock doesn't exist." This is not a code warning. It comes from the package manager cache, not from our source.)
    - No file was changed by this test step. `git status` shows the same 5 changed files as before this step started.
    - next: /review
  timestamp: 2026-09-05T11:46:24.350892+00:00
position_column: doing
position_ordinal: '80'
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
