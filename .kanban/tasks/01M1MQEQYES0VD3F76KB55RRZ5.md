---
assignees:
- claude-code
position_column: todo
position_ordinal: '9380'
title: 'Unblock the doctor work: push FoundationModelsExtras main and re-resolve this package'
---
## What

The `doctor` tasks need `Doctorable`, `DoctorRunner`, `DoctorReport`,
`HealthCheck`, `HealthStatus` and `PlainTextDoctorRenderer`. Those types are in
the working copy of `FoundationModelsExtras` at
`Sources/FoundationModelsExtras/Doctor/`, but the commits that added them are
**not pushed**: `origin/main` is at `8b4706d`, and this package's
`Package.resolved` pins `foundationmodelsextras` at revision `8b4706dc`. A
`swift package update` today does not get the Doctor module, so every doctor
task fails to compile.

Steps:

- In `../FoundationModelsExtras`, run its own test suite, then push `main`.
  **Ask the person before the push.** A push to a shared branch is an
  outward-facing action, and the local `main` holds more than the Doctor
  commits.
- In this package, run `swift package update FoundationModelsExtras`, and
  check `Package.resolved` now names a revision that holds the `Doctor/`
  directory.
- Prove the types are reachable from this package: a test imports
  `FoundationModelsExtras` and names each of the six types.
- Do the same in `IntegrationTests/Package.resolved`, which resolves its own
  copy.

This task changes no behaviour of this package. It exists because
`cli-plan.md` §15 says N5 is blocked by Extras D1 to D3, and the block is real
today for a different reason than the plan gives: the work is done, and it is
not published.

## Acceptance Criteria

- [ ] `origin/main` of `FoundationModelsExtras` holds the `Doctor/` directory.
- [ ] `Package.resolved` in this package names a revision that holds it.
- [ ] `IntegrationTests/Package.resolved` names the same revision.
- [ ] A file in this package can `import FoundationModelsExtras` and name
      `Doctorable`, `DoctorRunner`, `DoctorReport`, `HealthCheck`,
      `HealthStatus` and `PlainTextDoctorRenderer`.
- [ ] `swift build` and `swift test` still pass at the new revision.

## Tests

- [ ] New `Tests/FoundationModelsACPClientTests/ExtrasDoctorReachableTests.swift`.
      It names each of the six types in a type annotation, so the file fails
      to compile when the pin is wrong. It also asserts
      `HealthStatus.allCases`-equivalent coverage by naming `ok`, `warning`
      and `error`, and asserts `DoctorReport(checks: []).worstStatus` is `ok`.
- [ ] A test builds one `HealthCheck.error(name:message:fix:category:)` and
      asserts the factory signature the doctor tasks depend on.
- [ ] Run `swift test` and `swift test --package-path IntegrationTests`. Both
      succeed at the new revision.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.