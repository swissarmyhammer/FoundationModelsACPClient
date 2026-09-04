---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1pkyd1k1cn8wzzaf5e36709
  text: |-
    Picked up. Research done.

    **The push already landed — do not push anything.** `FoundationModelsExtras` `origin/main` is at `09eed09` ("chore(kanban): record the finish ledger for ps8ytcs"), and `git ls-tree -r origin/main Sources/FoundationModelsExtras/Doctor/` lists the whole module:

    - `Doctorable.swift`
    - `DoctorRenderer.swift`
    - `DoctorReport.swift`
    - `DoctorRunner.swift`
    - `HealthCheck.swift`

    Five files, six types: `HealthStatus` shares `HealthCheck.swift`, and `PlainTextDoctorRenderer` lives in `DoctorRenderer.swift`. The sibling working copy is clean and level with `origin/main`, so the first step of this card is already done and needs no outward-facing action.

    **State before the work.** Both resolution files pin `foundationmodelsextras` at revision `8b4706dc4d34bad02870fd12776474c5db1497c6` on branch `main` — `Package.resolved` and `IntegrationTests/Package.resolved` alike. That revision holds no `Doctor/` directory, which is the block the card records.

    **Package.resolved is gitignored in this repository** (`.gitignore` names `Package.resolved`). The acceptance rows about it stay true — SwiftPM writes the file during resolution, before any build — but the change will not show in a diff. The reachability test is what truly protects the pin, because the file fails to compile when the pin is wrong.

    **Real API, read from the source at `origin/main`:**

    - `Doctorable` — `doctorName: String`, `doctorCategory: String`, `isApplicable: Bool` (default `true`), `runHealthChecks() async -> [HealthCheck]`. Non-throwing.
    - `HealthStatus: String, Sendable, Codable` — cases `ok`, `warning`, `error`. No `CaseIterable`, so the test names the three cases directly.
    - `HealthCheck` — `init(name:status:message:fix:category:)` plus `ok(name:message:category:)`, `warning(name:message:fix:category:)`, `error(name:message:fix:category:)`.
    - `DoctorReport` — `init(checks:)`, `worstStatus`, `exitCode` (0 ok, 1 error, 5 warning).
    - `DoctorRunner` — `init(components: [any Doctorable])`, `run() async -> DoctorReport`.
    - `PlainTextDoctorRenderer` — `init(useColor: Bool = false)`, `render(_:) -> String`, `write(_:to:)`.

    **Plan:** write the failing reachability test first (it cannot compile at the old pin), then `swift package update FoundationModelsExtras` in both packages to reach GREEN.
  timestamp: 2026-09-04T16:27:33.811216+00:00
- actor: claude-code
  id: 01m1pmj3m10b3yza04fj5qeck2
  text: |-
    Implementation landed, by the red-green cycle.

    **RED.** Wrote `Tests/FoundationModelsACPClientTests/ExtrasDoctorReachableTests.swift` first and built it at the old pin. `swift build --build-tests` failed exactly as the card predicts, with `cannot find type 'Doctorable' in scope`, and the same for `DoctorRunner`, `DoctorReport`, `HealthCheck`, `HealthStatus` and `PlainTextDoctorRenderer`. The file is therefore a true guard: it cannot compile against a revision that lacks any one of the six types.

    **GREEN.** `swift package update FoundationModelsExtras` moved the root package from `8b4706dc4d34bad02870fd12776474c5db1497c6` to `09eed094a1a577171ff4f7fa4dffb021a21be676`. `swift package --package-path IntegrationTests update FoundationModelsExtras` moved the nested package to the same revision. No other pin moved: `foundationmodelsacp`, Noora, `swift-argument-parser`, `swift-syntax`, Yams and the rest all recomputed to the versions they already held.

    **What the test asserts.** Each of the six types stands in an explicit type annotation, and each test also asserts a behaviour the `doctor` subcommand depends on, so a passing run reports more than "the names resolve":

    - an empty report is `ok` — `DoctorReport(checks: [])`, with `let noChecks: [HealthCheck] = []`;
    - an error outranks a warning, and a warning outranks `ok` — this names all three `HealthStatus` cases;
    - the `error(name:message:fix:category:)` factory keeps its fix, name, category and status;
    - `DoctorRunner` gathers the finding of a component that conforms to `Doctorable`. The stub *conforms to* the protocol rather than only naming it, which is the stronger proof: a protocol the dependency does not carry cannot be conformed to;
    - `PlainTextDoctorRenderer` draws both halves of a failing finding — what broke, and what repairs it.

    **Discovery worth keeping.** `IntegrationTests/Package.swift` names no dependency on `FoundationModelsExtras` at all. It reaches the module transitively, through its path dependency on this package, which is why its own `Package.resolved` still carried the stale pin and needed its own update. A future card that changes an Extras pin must remember to re-resolve both packages; updating only the root leaves the integration suite behind.

    **Discovery worth keeping.** The root test target already declared `.product(name: "FoundationModelsExtras", …)`, so no manifest change was needed. `ManifestTests` reads that block, and it stayed green.

    **On `Package.resolved` and the diff.** `git status` after the work shows one source change only — the new test file. Neither resolution file appears, because `.gitignore` names `Package.resolved`. Both were rewritten on disk and both now read `09eed094a1a577171ff4f7fa4dffb021a21be676`, which was read back and verified. Reviewers must not look for the pin in the diff; the reachability test is the durable guard.

    ### implement — changed
    - evidence: 1 new file, `Tests/FoundationModelsACPClientTests/ExtrasDoctorReachableTests.swift`. Both `Package.resolved` files re-resolved `foundationmodelsextras` from `8b4706dc4d34bad02870fd12776474c5db1497c6` to `09eed094a1a577171ff4f7fa4dffb021a21be676` on branch `main` (gitignored, so not in the diff). RED verified first: the file failed to compile at the old pin with `cannot find type` for all six types. `timeout 420 swift test` — 153 tests in 9 suites passed, zero failures, zero warnings. `timeout 600 swift test --package-path IntegrationTests` — 4 tests in 1 suite passed. `timeout 420 swift build` — clean, no warnings. The new suite alone runs 5 tests, all passing. Nothing was pushed, and the sibling repository was not touched.
    - next: `/review`
  timestamp: 2026-09-04T16:38:19.521371+00:00
position_column: doing
position_ordinal: '80'
title: 'Unblock the doctor work: push FoundationModelsExtras main and re-resolve this package'
---
## What

The `doctor` tasks need `Doctorable`, `DoctorRunner`, `DoctorReport`,
`HealthCheck`, `HealthStatus` and `PlainTextDoctorRenderer`. Those types are in
the working copy of `FoundationModelsExtras` at
`Sources/FoundationModelsExtras/Doctor/`, but when this card was written the
commits that added them were **not pushed**: `origin/main` was at `8b4706d`,
and this package's `Package.resolved` pinned `foundationmodelsextras` at
revision `8b4706dc`. A `swift package update` then did not get the Doctor
module, so every doctor task failed to compile.

**The push already landed. Nothing was pushed from this card.** `origin/main`
of `FoundationModelsExtras` is at `09eed094a1a577171ff4f7fa4dffb021a21be676`,
and `git ls-tree -r origin/main Sources/FoundationModelsExtras/Doctor/` lists
the whole module — `Doctorable.swift`, `DoctorRenderer.swift`,
`DoctorReport.swift`, `DoctorRunner.swift` and `HealthCheck.swift`. Five files
hold the six types: `HealthStatus` shares `HealthCheck.swift`, and
`PlainTextDoctorRenderer` lives in `DoctorRenderer.swift`. The sibling working
copy is clean and level with `origin/main`. This card took no outward-facing
action, and the sibling repository was not touched.

Steps:

- ~~In `../FoundationModelsExtras`, run its own test suite, then push `main`.~~
  **Already done, outside this card.** `origin/main` is at `09eed09` and holds
  the `Doctor/` directory.
- In this package, run `swift package update FoundationModelsExtras`, and
  check `Package.resolved` now names a revision that holds the `Doctor/`
  directory.
- Prove the types are reachable from this package: a test imports
  `FoundationModelsExtras` and names each of the six types.
- Do the same in `IntegrationTests/Package.resolved`, which resolves its own
  copy.

Note on `Package.resolved`: `.gitignore` names it, so neither resolution file
appears in a diff. The acceptance rows below still hold — SwiftPM writes the
file during resolution, before any build — but the reachability test is what
truly protects the pin, because that file fails to compile when the pin is
wrong.

This task changes no behaviour of this package. It exists because
`cli-plan.md` §15 says N5 is blocked by Extras D1 to D3, and the block was real
for a different reason than the plan gives: the work was done, and it was
not published.

## Acceptance Criteria

- [x] `origin/main` of `FoundationModelsExtras` holds the `Doctor/` directory.
- [x] `Package.resolved` in this package names a revision that holds it.
      It names `09eed094a1a577171ff4f7fa4dffb021a21be676`.
- [x] `IntegrationTests/Package.resolved` names the same revision.
- [x] A file in this package can `import FoundationModelsExtras` and name
      `Doctorable`, `DoctorRunner`, `DoctorReport`, `HealthCheck`,
      `HealthStatus` and `PlainTextDoctorRenderer`.
- [x] `swift build` and `swift test` still pass at the new revision.

## Tests

- [x] New `Tests/FoundationModelsACPClientTests/ExtrasDoctorReachableTests.swift`.
      It names each of the six types in a type annotation, so the file fails
      to compile when the pin is wrong. It also asserts
      `HealthStatus.allCases`-equivalent coverage by naming `ok`, `warning`
      and `error`, and asserts `DoctorReport(checks: []).worstStatus` is `ok`.
- [x] A test builds one `HealthCheck.error(name:message:fix:category:)` and
      asserts the factory signature the doctor tasks depend on.
- [x] Run `swift test` and `swift test --package-path IntegrationTests`. Both
      succeed at the new revision.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.