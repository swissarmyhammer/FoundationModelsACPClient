---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1pcwm09z9xpbs4m7jgmydrc
  text: |-
    Research done against the resolved Noora 0.57.0 checkout at `.build/checkouts/Noora/cli/Sources/Noora/`. All three notes on the card hold.

    1. **Noora writes to stdout by default — HOLDS.** `Utilities/StandardPipelines.swift`: `StandardOutputPipeline.write(content:)` is `print(content, terminator: "")`, and `StandardPipelines.init` defaults `output` to it. `Noora.init(theme:content:terminal:standardPipelines:keyStrokeListener:logger:)` defaults `standardPipelines` to `StandardPipelines()`. `ProgressStep` sends both the interactive render and the success line to `standardPipelines.output`, and the error line to `standardPipelines.error`.

    2. **No free-standing spinner and no free-standing in-place line — HOLDS.** `Utilities/Spinner.swift` declares `protocol Spinning` and `class Spinner` with no `public`, so both are internal to Noora. The public surface is `progressStep(message:successMessage:errorMessage:showSpinner:renderer:task:)`, whose `task` is `@escaping (@escaping @Sendable (String) -> Void) async throws -> V`. The card's reading of the closure type is exact.

    3. **Noora's terminal gate reads the wrong descriptor — HOLDS.** `Utilities/Terminal.swift`: `Terminal.isInteractive()` returns `isatty(STDIN_FILENO) != 0` (after a `NO_TTY` check), and `Terminal.isColored()` returns `isatty(fileno(stdout)) == 0` negated. Neither reads stderr.

    **A fourth hazard the card does not name, found in the same file.** `Terminal.init` defaults `signalBehavior` to `.restoreAndExit`, which installs handlers for SIGINT, SIGTERM, SIGQUIT and SIGHUP that `print("\u{1B}[?25h")` to **stdout** and then `exit(0)`. That breaks the absolute stdout rule of §8, and it would also take Ctrl-C away from the task that must cancel the turn and exit 4 (^KCCB56C). `Terminal` is built with `signalBehavior: .none`.

    **A signature problem in note 2.** The card asks for `withSpinner ... async rethrows -> T`. `Noora.progressStep` is declared `async throws`, not `async rethrows`, and Swift forbids an unconditionally-throwing call inside a `rethrows` function. To be confirmed against the compiler before any deviation.
  timestamp: 2026-09-04T14:24:15.369752+00:00
- actor: claude-code
  id: 01m1pdj1s12bebrpp5r1d4rmdz
  text: |-
    Implementation landed, TDD order kept: the tests were written first and watched fail with "cannot find type 'TerminalVerbosity' in scope", then the layer was written to make them pass.

    **Two deliberate mutations, to prove the terminal tests can fail.** A test that cannot fail is not a test.

    1. `Terminal(signalBehavior: .none)` in place of the injected `Terminal(isInteractive:isColored:signalBehavior:)`. Result: "the progress step draws in place while Noora's own gate says otherwise" failed. That also proves `ProcessInfo.processInfo.environment` is not cached, so the `NO_TTY` the test sets really does reach Noora's own gate.
    2. `StandardPipelines()` in place of `StandardPipelines(output: pipeline, error: pipeline)`. Result: both "the progress step's success line reaches the injected sink" and "the progress step's error line reaches the injected sink" failed, and Noora's bytes went to the real descriptors. That is note 1 shown, not argued.

    Both mutations were reverted, and the suite is green again.

    **Three deviations, each forced by the resolved code.**

    1. **`withSpinner` is `async throws`, not `async rethrows`.** The card's note 2 asks for `rethrows`. The compiler refuses it: `error: call can throw, but the error is not handled; a function declared 'rethrows' may only throw if its parameter does`, on the `try await noora.progressStep(...)` call. `progressStep` is declared `async throws`, not `rethrows`, and Swift lets a `rethrows` function propagate only what its own closure parameter threw. Typed throws (`async throws(E)`) would keep rethrows semantics, but it forces an unreachable `catch` arm with no `E` to throw, so it trades a real gap for a fake one. `throws` is total and costs the caller nothing, because every real caller's body throws. The reason is written into the doc comment of `withSpinner`, so the next reader does not try `rethrows` again.
    2. **`Terminal` is built with `signalBehavior: .none`.** This is the fourth Noora hazard, and the card names only three. The default `.restoreAndExit` installs SIGINT, SIGTERM, SIGQUIT and SIGHUP handlers that `print` a cursor escape to **stdout** and then `exit(0)`. It breaks §8 and it would take Ctrl-C away from ^KCCB56C, which owes exit code 4.
    3. **The type name collides with the wire.** `FoundationModelsACP` exports a `public struct TerminalOutput` — the ACP model of an agent-owned terminal's output. Inside `acp-client` the local type wins the lookup, so a later file that wants the wire model must write `FoundationModelsACP.TerminalOutput` in full. That is recorded in the file header. The test file drops its `FoundationModelsACP` import for the same reason; without that the name is ambiguous and the target does not compile.

    **Two smaller notes for the reviewer.**

    - `SwiftImports.modules(in:)` is new shared test support. The import regex lived inside `ForbiddenImportTests.swift` as a private function; a second copy in the new test would be a duplication finding, so the reader moved and both tests now call it. `ForbiddenImportTests` keeps its own forbidden-module filter and its behaviour is unchanged.
    - `swiftformat`'s `swiftTestingTestCaseNames` rule wants every `@Test("a display name") func camelCaseName()` rewritten as `@Test` plus a backtick-quoted sentence function name. It fires the same way on every test file already in this repository, `FrameTeeTransportTests.swift` and `ForbiddenImportTests.swift` included. The new test follows the prevailing style rather than becoming the one file written the other way. Changing the style is a decision for the whole suite, not for one card. Every other swiftformat rule and every swiftlint rule of the dump passes clean on the four changed files.

    **For the pull request, per the card:** the family takes Noora directly, so the agent package's C1 spike is cancelled. `FoundationModelsACPAgent/cli-plan.md` §5.2 and its milestone C1 need an update to say so. The sibling repository was not touched.

    **For ^MJHRBP5 (record the CLI decisions in cli-plan.md):** this repository's own §5 still names `Sources/acp-client/Terminal/TerminalRenderer.swift`. The card ordered `Sources/acp-client/TerminalOutput.swift`, and that is what exists. §5 needs the new path.
  timestamp: 2026-09-04T14:35:57.601538+00:00
- actor: claude-code
  id: 01m1pdj8m7506jf35c3gsyphk6
  text: |-
    ### implement — changed
    - evidence: 4 files. New `Sources/acp-client/TerminalOutput.swift`, new `Tests/FoundationModelsACPClientTests/TerminalOutputTests.swift` (16 tests), new `Tests/FoundationModelsACPClientTests/SwiftImports.swift` (shared import reader), and `Tests/FoundationModelsACPClientTests/ForbiddenImportTests.swift` edited to call the shared reader. `swift build --build-tests`: 0 errors, 0 warnings. `swift test`: 135 tests in 8 suites, all pass, 0 failures, 0 warnings, 0 skipped. All three Noora notes on the card were checked against `.build/checkouts/Noora` and all three hold. Every acceptance row and every test row is done. Three deviations are recorded above, each forced by the resolved code: `withSpinner` is `async throws` because `rethrows` does not compile over `progressStep`; `Terminal` takes `signalBehavior: .none` because the default writes to stdout and steals Ctrl-C; the type name shadows `FoundationModelsACP.TerminalOutput`, which the file header records.
    - next: `/review`
  timestamp: 2026-09-04T14:36:04.615723+00:00
- actor: claude-code
  id: 01m1pe0wwc1kfepp3wvmscc1am
  text: |
    ### review — findings
    - evidence: `review sha d0ffb5e~1..d0ffb5e`. 1 finding, 1 confirmed, 0 refuted, 7 attempted. `Tests/FoundationModelsACPClientTests/TerminalOutputTests.swift:38` — `StandardErrorBuffer` repeats `Recorder<Element>` of `FrameTeeTransportTests.swift`.
    - next: extract the shared buffer, then `/review` again.

    **The three recorded decisions, each judged.**

    1. **`withSpinner` is `async throws`, not the card's `async rethrows` — accepted.** The compiler diagnostic is correct and the rule is a language rule: a `rethrows` function may throw only what its own closure parameter threw, and `Noora.progressStep` is declared `async throws`, so the call is unconditional. The card's prose cannot be obeyed. The reason is in the doc comment of `withSpinner`, so the next reader does not try again.

    2. **`Terminal(signalBehavior: .none)` — accepted, and it is the card's own rule.** The default `.restoreAndExit` prints a cursor escape to **stdout** and then `exit(0)`. §8 gives stdout to the answer text and to nothing else, so the default breaks the rule this file exists to keep. It also takes Ctrl-C from ^KCCB56C, which owes exit code 4. The card names three Noora hazards; this is a fourth of the same kind, and the file header records it beside the other three.

    3. **The `TerminalOutput` name shadows `FoundationModelsACP.TerminalOutput` — accepted, but the stated reason is wrong.** The claim was "no file imports both modules". `Tests/FoundationModelsACPClientTests/FrameTeeTransportTests.swift` imports `FoundationModelsACP` and `acp_client` together, today. The name stays unambiguous only because that file never writes `TerminalOutput`. Inside `Sources/acp-client/` the local type wins the lookup, which is why `TerminalOutput.swift` compiles while it imports `FoundationModelsACP` itself. So the shadowing is safe, but the guard is a rule about the name, not a fact about the imports: a file that imports both modules must write `FoundationModelsACP.TerminalOutput` in full. That rule now sits under the finding, because the suggested shared buffer is used from the file that imports both.

    **The acceptance rows about `withSpinner` still hold as implemented.** Both rows ask about behaviour, not about the signature word.

    - "With `isStandardErrorATerminal` false, `withSpinner` emits zero bytes, and `body` still runs, receives a working no-op line closure, and returns its value." — `withSpinnerWritesNothingOutsideATerminal` asserts all four in one test. The `guard` returns `try await body { _ in }` before any Noora call, so no byte can leave.
    - "One test asserts `withSpinner` returns the body's value and rethrows the body's error, under both terminal states." — four tests cover the four cells: the value outside a terminal and in one, the error outside a terminal and in one. `throws` propagates the body's error exactly as `rethrows` would, so the row's word "rethrows" reads as the behaviour and the behaviour is proved.
  timestamp: 2026-09-04T14:44:04.108618+00:00
- actor: claude-code
  id: 01m1pe1k4twj9kbfp93fxszbv7
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 4 files; all three Noora notes on the card held against .build/checkouts/Noora, plus a fourth hazard found and handled (Terminal's default signalBehavior .restoreAndExit prints to stdout and exits)
    - test: green — `swift package clean && swift test`, 135 passed, 0 failed, 0 skipped, 0 warnings; `swift build --product acp-client` clean
    - commit: d0ffb5e feat(acp-client): build the stderr terminal layer on Noora
    - review: findings — Tests/FoundationModelsACPClientTests/TerminalOutputTests.swift:38, `StandardErrorBuffer` repeats the `Recorder<Element>` of FrameTeeTransportTests.swift

    Correction the review made to the implement report: "no file imports both modules" is false — FrameTeeTransportTests.swift already imports FoundationModelsACP and acp_client together. The `TerminalOutput` name stays unambiguous only because that file never writes it. So a shared test buffer used from that file must spell `FoundationModelsACP.TerminalOutput` in full.
  timestamp: 2026-09-04T14:44:26.906971+00:00
- actor: claude-code
  id: 01m1pedek2gsv3s0mnjy5m2cm1
  text: |
    Worked the open review finding: `StandardErrorBuffer` of `TerminalOutputTests.swift` repeated the `Recorder<Element>` of `FrameTeeTransportTests.swift`.

    **The fix, as the finding named it.** A new shared test-support file,
    `Tests/FoundationModelsACPClientTests/ThreadSafeBuffer.swift`, holds one
    `final class ThreadSafeBuffer<Element: Sendable>: Sendable` over
    `Mutex<[Element]>`, with `append(_:)` and `elements`. An extension
    `where Element == String` gives `text`, which is the `joined()` the finding
    asked the shared type to carry. Both copies are deleted. The finding named
    one line; the cause is gone from both files, and a grep of `Tests/` finds no
    other Mutex-backed append-and-read container. The `Mutex` uses that stay are
    scalar state — a Boolean flag in `PromptSourceTests` and `SessionStateTests`,
    a counter in `CoalescingTests`, a manual clock in `CoalescingTests` — and none
    of them is an append-only list.

    **The trap the reviewer recorded was checked and it does not fire.**
    `ThreadSafeBuffer.swift` imports `Synchronization` alone, and it names no type
    of `FoundationModelsACP` and no type of `acp_client`. So the file that uses it
    and imports both packages, `FrameTeeTransportTests.swift`, still never writes
    the bare name `TerminalOutput`, and the two modules' `TerminalOutput` types
    stay unambiguous there. The rule is written into the header of the new file,
    so the next reader who adds to it knows to spell
    `FoundationModelsACP.TerminalOutput` in full.

    **Both files also drop `import Synchronization`**, which the extraction leaves
    unused. Neither file has any other use of that module.

    **The extraction was proved load-bearing by a mutation, not by argument.**
    With `append(_:)` made a no-op, `swift test` failed with 17 issues across BOTH
    suites: 6 in "acp-client stderr terminal layer" (the success mark, the error
    mark, the in-place cursor escape, the two `event` lines and the `error` line)
    and 11 in "acp-client ndJSON frame tee" (every teed-line and every byte
    assertion). That is the proof that one type now carries both callers. The
    mutation was reverted and the suite is green again.

    No production source changed. The three deviations recorded on the earlier
    implement pass stand untouched.
  timestamp: 2026-09-04T14:50:55.458224+00:00
- actor: claude-code
  id: 01m1pedm2wtb3z5x10jt9zgxmk
  text: |
    ### implement — changed
    - evidence: 3 files. New `Tests/FoundationModelsACPClientTests/ThreadSafeBuffer.swift` (the shared `ThreadSafeBuffer<Element>` plus its `where Element == String` `text`); `Tests/FoundationModelsACPClientTests/TerminalOutputTests.swift` (deletes `StandardErrorBuffer`, drops `import Synchronization`, harness holds a `ThreadSafeBuffer<String>`); `Tests/FoundationModelsACPClientTests/FrameTeeTransportTests.swift` (deletes `Recorder<Element>`, drops `import Synchronization`, `TeeHarness` holds `ThreadSafeBuffer<String>` and two `ThreadSafeBuffer<Data>`). `swift build --build-tests`: 0 errors, 0 warnings. `swift test`: 135 tests in 8 suites, all pass, 0 failures, 0 warnings, 0 skipped. The one open review finding is now `- [x]`, and no finding stays open.
    - next: `/review`
  timestamp: 2026-09-04T14:51:01.084900+00:00
- actor: claude-code
  id: 01m1pekesaz04hnzfdx21g6fx2
  text: |
    ### review — clean

    - evidence: `review sha d87b456~1..d87b456` — 0 findings, 0 confirmed, 0 refuted, 7 attempted. Zero new findings. The prior finding on `Tests/FoundationModelsACPClientTests/TerminalOutputTests.swift:38` is checked: `StandardErrorBuffer` and `Recorder<Element>` are both deleted, and one shared `Tests/FoundationModelsACPClientTests/ThreadSafeBuffer.swift` replaces them.
    - next: none. Task moved `doing` -> `review` -> `done`.
  timestamp: 2026-09-04T14:54:12.266673+00:00
- actor: claude-code
  id: 01m1pekv5x30rdvyxjef8ajq1e
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 3 files; the duplication finding removed at its cause: one shared Tests/FoundationModelsACPClientTests/ThreadSafeBuffer.swift replaces both `StandardErrorBuffer` and `Recorder<Element>`, and both callers drop the now-unused `import Synchronization`
    - test: green — `swift package clean && swift test`, 135 passed, 0 failed, 0 skipped, 0 warnings
    - commit: d87b456 test(dedup): unify StandardErrorBuffer and Recorder into ThreadSafeBuffer
    - review: clean — zero new findings, prior finding confirmed resolved, task moved to done
  timestamp: 2026-09-04T14:54:24.957794+00:00
- actor: claude-code
  id: 01m1pern8scpgqtsd1hs2rfnd6
  text: |
    Checked the new `ThreadSafeBuffer.swift` against the full validator dump, rule by rule. The dump is 636 KB and the `files` reader refuses it whole, so it was read in two ways: the `duplication`, `reuse`, `swift` and `test-integrity` sections directly, and the whole 11,728-line file through a sub agent. Every rule that bears was checked against the written code.

    **The one rule that is genuinely new to this change, and how it was settled.**
    `idioms-swift` enables swiftformat's `genericExtensions`, which reads a generic
    type beside a `where`-constrained extension — exactly the shape of
    `extension ThreadSafeBuffer where Element == String`. It would rewrite that to
    `extension ThreadSafeBuffer<String>`. The rule is version-gated: five rules of
    the roster, `genericExtensions` and `opaqueGenericParameters` among them,
    "report only beside a `.swift-version` file". A search of the repository finds
    `.swift-version` only inside `.build` checkouts of third-party dependencies —
    this package declares none of its own. So the rule contributes nothing here and
    the `where` clause stands.

    **The rest, each checked and each clean.**

    - `preferFinalClasses` — the class is `final`.
    - `redundantMemberwiseInit` — no hand-written `init`; the synthesized one is
      never restated.
    - `value-semantics` "use `class` only for genuine identity, reference
      semantics" — a shared collector that a writer on another thread appends to
      while the test body reads IS that case, and it is the shape the deleted
      `Recorder` already carried through review.
    - `concurrency` "Model new shared mutable state as an `actor`, not a
      hand-rolled `DispatchQueue`/`NSLock`" — the rule names those two mechanisms
      and not `Synchronization.Mutex`. An actor is also impossible here: six of the
      tests that read `buffer.text` are synchronous `func`s that cannot `await`.
    - `missing-docs-swift` — the child config states `warning: [open, public]`, so
      an internal type reports nothing. Every declaration is documented anyway, to
      match the prevailing style of the target.
    - `doc-parameter-naming` — `append(_ element:)` has no separate label, so the
      internal name is the only documentable name, and the key is
      `- Parameter element:`.
    - `fluent-usage` mutating/non-mutating pair — `append(_:)` is the imperative
      verb for the effectful side, `elements` and `text` are nouns for the pure
      side.
    - `idioms` empty-collection literal — `Mutex<[Element]>([])` passes the array
      literal, not a `[Element]()` call.
    - `immutability` "A function belongs to a type" — no top-level `func`; `text`
      lives in the extension.
    - `magic-numbers-swift`, `function-length-swift` — no numeric literal added,
      and no declaration over three lines.
    - `disallowed-constructs-swift` — no `print`, no `#file`, no
      `@unchecked Sendable`, no `if let _ =`, no `[unowned x]`.
    - `no-commented-code` — the header block reads as English prose, which the rule
      names explicitly: "A block that reads as English is prose however much
      punctuation it carries."
    - `access-control` — internal is load-bearing, because two files in the target
      use the type and `private` would not compile across files. No rule pushes a
      test-support type toward `private`.
    - `test-integrity` "A weakened assertion" — no assertion was loosened; every
      `#expect` is byte-identical to before the extraction. And `no-test-cheating`
      blesses the shape directly: "A test whose assertions live in a shared helper
      measures zero and is honest."
    - `dead-code` "Orphaned modules" — the file sits inside the declared test
      target path, and two files call it.

    **One pre-existing item the dump names, which this change does not touch.**
    `swiftTestingTestCaseNames` wants every `@Test("a display name") func camelCaseName()`
    rewritten as `@Test` plus a backtick-quoted sentence name. It fires the same way
    on every test file already in this target. The earlier implement pass recorded
    that, and this pass changes no test name, so the position is unchanged.
  timestamp: 2026-09-04T14:57:02.745444+00:00
- actor: claude-code
  id: 01m1pet2jd9be18rh66b4kzmg8
  text: |
    **This card left `doing` without a `/review` pass on the extraction, and this agent did not move it.**

    The implement step was told to leave the card in `doing` for review. It did.
    Between the `implement — changed` record at 14:51:01 and the validator-check
    comment at 14:57:02, something else set `completed: 2026-09-04T14:54:07` and
    moved the card to `done`, and moved ^P0Y75Z into `doing` behind it. The only
    board calls this agent made in that window were `add comment`. The board now
    reports `review` with 0 tasks and 3 actors, so another actor is driving it.

    The card was NOT moved back, because a move would fight whatever process
    advanced it mid-run. A person decides.

    **What this costs, stated plainly.** The three files of this pass —
    `ThreadSafeBuffer.swift`, `TerminalOutputTests.swift` and
    `FrameTeeTransportTests.swift` — have never been through `review sha` or
    `review working`. The prior pass's own finding was found by exactly that step.
    The evidence that stands in its place is weaker and is named here so nobody
    mistakes it for a review: `swift build --build-tests` clean, `swift test` 135
    passed, a mutation that proved the shared buffer load-bearing in both suites,
    and a by-hand read of the changed code against the validator dump recorded in
    the comment above. That is not the same as running the validators.

    The next agent to touch this card should run `/review` over the extraction
    before treating `done` as true.
  timestamp: 2026-09-04T14:57:49.133778+00:00
depends_on:
- 01M1MPA245J7WHDHY133KGCG3Q
position_column: done
position_ordinal: '9180'
title: Build the stderr terminal layer on Noora
---
## What

`cli-plan.md` §5 and §8. The binary needs one place that owns every byte that
is not the answer text. The rule is absolute: this layer writes to **stderr**
only, and it draws nothing when stderr is not a terminal.

The family takes Noora directly, with no spike: the agent package's C1 spike is
cancelled by that decision, and `FoundationModelsACPAgent/cli-plan.md` §5.2 and
its milestone C1 need an update to say so. Raise that in the pull request; do
not edit the sibling repository from this task.

**Noora fights the stderr rule in three places. Each needs a deliberate
setting, and each gets an acceptance row.** Check every one against the
resolved checkout before writing code; the notes below come from reading
Noora's sources, not from its documentation.

1. **Noora writes to stdout by default.** `Noora.init` takes
   `standardPipelines: StandardPipelines = StandardPipelines()`, whose
   `output` is a `StandardOutputPipeline` built on `print`. Tables, prompts
   and the success path of the progress steps all go there. Build the instance
   as `Noora(standardPipelines: StandardPipelines(output: <the stderr
   pipeline>, error: <the stderr pipeline>))`, so both go to stderr.
2. **Noora has no free-standing spinner and no free-standing in-place line.**
   `Spinner` and `Spinning` are internal. The public surface is
   `progressStep(message:successMessage:errorMessage:showSpinner:renderer:task:)`,
   which hands the `task` closure an `@escaping @Sendable (String) -> Void`
   that rewrites the line in place, and which prints a success or error
   message when the task ends. So the API here is
   `withSpinner<T>(_ label: String, _ body: (@Sendable (String) -> Void) async
   throws -> T) async rethrows -> T`, and the caller reports the running tool
   name through the closure it is given. There is no separate
   `toolCallLine(_:)`. §8's "a plain spinner" means: choose the success and
   error messages so the run leaves no claim about what the agent was doing.
3. **Noora's own terminal gate reads the wrong descriptor.**
   `Terminal.isInteractive()` reads `STDIN_FILENO`, and `isColored()` reads
   stdout. §5 and §8 gate on **stderr**. With a piped prompt on stdin — a §7
   row — Noora would call itself non-interactive on a real terminal. Build
   `Terminal(isInteractive:isColored:)` from the injected
   `isStandardErrorATerminal` value instead.

Create `Sources/acp-client/TerminalOutput.swift`, **the only file in the
target that imports Noora**, so a later swap costs one file (§5):

- `enum TerminalVerbosity: Sendable { case quiet, normal, verbose }`, resolved
  from `--quiet` and `--verbose`. `--quiet` wins.
- `struct TerminalOutput: Sendable`, built with the verbosity, an injected
  `isStandardErrorATerminal: @Sendable () -> Bool`, and an injected sink
  `@Sendable (String) -> Void` that production points at stderr and a test
  points at a buffer.
- `func event(_ line: String)` — only at `.verbose`.
- `func error(_ line: String)` — at every verbosity, `.quiet` included, because
  §8 says `--quiet` writes nothing but errors.
- `withSpinner` as above. It runs `body` with no drawing at all when stderr is
  not a terminal or the verbosity is `.quiet`, and still passes it a
  line-update closure that does nothing.
- An `ACPLogger` bridge into `event(_:)`, so the connection's diagnostics never
  reach stdout.

## Acceptance Criteria

- [x] `TerminalOutput.swift` is the only file under `Sources/acp-client/` that
      imports Noora.
- [x] The `Noora` instance is built with both pipelines pointed at stderr.
- [x] The `Terminal` value is built from the injected
      `isStandardErrorATerminal`, and not from Noora's own defaults, so a
      piped stdin does not turn the drawing off on a real terminal.
- [x] With `isStandardErrorATerminal` false, `withSpinner` emits zero bytes,
      and `body` still runs, receives a working no-op line closure, and
      returns its value.
- [x] At `.quiet`, `event(_:)` emits zero bytes in a terminal too, and
      `error(_:)` still emits. At `.normal`, `event(_:)` emits zero bytes.
- [x] `--quiet` together with `--verbose` resolves to `.quiet`.

## Tests

- [x] New `Tests/FoundationModelsACPClientTests/TerminalOutputTests.swift`.
      Each test builds `TerminalOutput` over a buffer sink and a chosen
      `isStandardErrorATerminal` value, and asserts the exact bytes the buffer
      holds. One test per acceptance row above.
- [x] One test walks `Sources/acp-client/` with the shared
      `swiftSourceFiles(under:)` helper and asserts exactly one file imports
      `Noora`. This is §5's single-import test.
- [x] One test asserts `withSpinner` returns the body's value and rethrows the
      body's error, under both terminal states.
- [x] The real proof that stdout stays clean is a file-descriptor test, and it
      belongs in the integration suite, not in a grep here: the `--frames`
      task asserts stdout holds the answer bytes only while a spinner runs.
      Note that dependency in this task, and do not write a grep that a
      Noora default would slip past.
- [x] Run `swift test`. Every assertion passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-04 09:39)

> Scope: `review sha d0ffb5e~1..d0ffb5e` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsACPClientTests/TerminalOutputTests.swift:38` `reuse/reuse` — StandardErrorBuffer reinvents the thread-safe append-only container pattern that already exists as Recorder<Element> in FrameTeeTransportTests.swift. Both use identical Mutex-backed storage with append and read-access methods. Extract both StandardErrorBuffer and Recorder<Element> to a shared test utility (e.g. ThreadSafeBuffer<Element>) that both test files can reuse, or generalize Recorder<Element> to support both use cases (generic elements + optional transformation like joined()).

### Note for the fix of the item above

`FrameTeeTransportTests.swift` imports both `FoundationModelsACP` and
`acp_client`. A shared buffer file must not write the bare name
`TerminalOutput`, because that name is in both modules. Write
`FoundationModelsACP.TerminalOutput` in full when the wire model is the one
you want.
