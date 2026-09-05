# CLI Plan — `acp-client`

This plan adds one executable to this package. It stands on its own. It
cites `plan.md` for the rules that it keeps, and it states its own rules
where the two differ. `plan.md` does not change.

Two sibling plans go with it:

- `FoundationModelsExtras/doctor-plan.md` — the `Doctorable` protocol
  that §10 builds on.
- `FoundationModelsACPAgent/cli-plan.md` — the `acp-agent` binary this
  one tests.

## 1. Purpose

`acp-client` is a command-line client for **any** ACP v2 agent. You give
it an agent command and a prompt. It starts the agent, runs one turn,
prints the answer, and exits. With `--frames` it also shows every ndJSON
message in both directions.

It is a tool for a person who debugs an agent, and it is the driver of
the interop test.

## 2. Why it belongs in this package

`plan.md` states the design principle: "a client, not *our* client". Its
testing strategy already asks for this binary, but it does not name it:

> **Interop** — drive a *foreign* ACP agent binary over stdio, proving
> the no-knowledge-of-our-runtime claim is real rather than aspirational.

A test can make that claim. An executable proves it, because a person can
point it at any agent and watch the frames. The container is already
headless-usable, and `plan.md` says so: "staying SwiftUI-free keeps it
usable from AppKit, from a CLI, and headless-testable." This binary is
that CLI.

## 3. The binary

| Item | Value |
|---|---|
| Name | `acp-client` |
| Kind | An executable target, and an executable product |
| Links | `AcpClientCore` |
| Path | `Sources/acp-client/` |

It is a **product**, and not only a target. Another package must be able
to depend on it, so that package's tests can spawn it beside their own
binaries.

The executable holds the `@main` type and nothing else. Everything it
does lives in a library beside it:

| Item | Value |
|---|---|
| Name | `AcpClientCore` |
| Kind | A library target, and a library product |
| Links | Five: this package, `FoundationModelsACP`, `FoundationModelsExtras`, `ArgumentParser` and `Noora` |
| Path | `Sources/AcpClientCore/` |

The links are **five**, and `FoundationModelsExtras` is one of them. §10
builds the `doctor` subcommand on the Extras `Doctorable` module, so the
family leaf is a dependency of the client and not of the container alone.
§12 states the same count, and `ManifestTests` reads `Package.swift` and
counts it.

The library is a **product** for the same reason the binary is, and for a
second one: SwiftPM publishes no importable module for an executable
product across a package boundary, so a nested package can name the
client's types only through a library product. The `IntegrationTests`
package drives the health checks of §10 that way, rather than through the
spawned binary.

## 4. The parser

The binary uses **swift-argument-parser**. It writes no parser of its
own. The library gives `--help`, `--version`, the subcommand tree, and
the usage errors.

The parser costs no new package checkout. `FoundationModelsExtras`
already declares `apple/swift-argument-parser` from 1.8.0, and this
package already depends on Extras, so the library stands in
`Package.resolved` today. `Package.swift` declares
`apple/swift-argument-parser` directly, with the same version floor,
because the binary wants the parser only and not the `Operations` fusion
machinery that re-exports it.

**The terminal package of §5 does cost more.** Noora brings three
packages of its own into the graph: `onevcat/Rainbow`, `apple/swift-log`
and `tuist/path`. Those three are the price of §5, and the comment beside
the Noora dependency in `Package.swift` is where a reader meets it.

## 5. The terminal output

The bar is a good Rust CLI. The family takes **Noora** (Tuist), a Swift
CLI design system that covers what indicatif, dialoguer, comfy-table and
owo-colors cover in Rust.

**The agent package made that decision, and this package follows it.**
`FoundationModelsACPAgent/cli-plan.md` §5.2 reads "We adopt Noora", and
it states that the choice sets the family precedent and that the client
CLI follows it. Noora is taken directly, and no spike compares it with
another package: §5.2 makes the choice, and its milestone C1 asks for no
comparison. Two CLIs in one family that draw tables differently is a
defect a user sees, so one decision serves both. The comment beside the
Noora dependency in `Package.swift` states the same owner.

§5.2 names a different file, because each package contains the import in
a file of its own: `TerminalRenderer.swift` in the agent package, and the
file named below here.

**The risk, recorded.** Noora's own CI runs on macOS 15. This package
needs macOS 27, so no run upstream covers the platform this binary runs
on. A Noora release can therefore break this package with no red mark
upstream. The containment rule below is what holds that risk to one file.

The containment rule is: **one file imports Noora.**
`Sources/AcpClientCore/TerminalOutput.swift` vends a spinner, a
progress bar and a table, and every other file calls that type. A test
pins the single import over both source directories of §3, so a swap
costs one file.

That file makes two decisions Noora's own defaults do not make:

- It builds Noora's `Terminal` with `signalBehavior: .none`. The default
  is `.restoreAndExit`, which installs handlers for SIGINT, SIGTERM,
  SIGQUIT and SIGHUP. Those handlers print a cursor escape to **stdout**,
  and then they exit 0. That writes to the one descriptor §8 keeps for
  the answer, and it takes `Ctrl-C` away from §11, which §9 exits 4.
- It reads `isatty` on **stderr** itself. Noora's own gate reads the
  wrong descriptor: `Terminal.isInteractive()` reads stdin, and
  `Terminal.isColored()` reads stdout.

The rule is absolute: the terminal package writes to **stderr** only, and
it draws nothing when stderr is not a terminal. §8 holds stdout to the
answer text alone.

## 6. The subcommands

```
acp-client run <prompt> -- <agent-command> [agent-args...]
acp-client probe -- <agent-command> [agent-args...]
acp-client doctor -- <agent-command> [agent-args...]
acp-client --help      Print the usage to stdout, and exit 0.
acp-client --version   Print the version to stdout, and exit 0.
```

| Subcommand | Job |
|---|---|
| `run` | Start the agent, run one turn, print the answer, exit. This is the default. |
| `probe` | Start the agent, initialize, and print what it reports: the protocol version, the agent capabilities, the authentication methods, and the slash commands. Run no turn. |
| `doctor` | Check that this agent works: the command exists, it starts, `initialize` answers, and the version matches. See §10. |

`probe` and `doctor` answer two different questions. `probe` says **what
the agent supports**, and it always exits 0 when the agent answers.
`doctor` says **whether the agent is usable**, and its exit code carries
the verdict.

**The `--` separator is required.** Everything after it is the agent
command, with its own arguments. The binary never splits a command string
into words, so no quoting rule can go wrong, and an agent keeps its own
flags:

```
acp-client run "write a haiku" -- acp-agent acp
acp-client probe -- npx @some-vendor/their-acp-agent --model small
```

With no `--`, the command prints the usage to stderr and exits 2. There
is no default agent. A default would name one agent, and the
no-knowledge-of-our-runtime claim would stop being true.

### 6.1 The options

| Option | Effect |
|---|---|
| `--cwd <path>` | The working directory of the **session**. Default: the process working directory. |
| `--frames` | Write every ndJSON message to stderr, in both directions, with a direction mark. |
| `--timeout <seconds>` | End the run if the turn does not stop in time. Default: no limit. |
| `--verbose` | Write the session events to stderr. See §8. |
| `--quiet` | Draw no progress and no decoration, in a terminal too. |
| `--json` | `probe` and `doctor` only: write the report to stdout as JSON. |

`--frames` is the reason the binary exists. It shows the protocol
exchange, so a person can see what an agent sent.

**`--cwd` names the session, and never this process.** `run` and `probe`
each open a session, and each sends the value in `session/new`. The
binary never changes its own working directory. `--cwd` goes to the
agent exactly as typed. The binary does not resolve the value, does not
normalize it, and does not check it. The agent owns the file system of
the session, and the agent can be on a different machine, so the agent
is the only judge of the path. A relative value is the agent's to
refuse, and a path that names no directory is the agent's to refuse. The
binary reports that refusal as an agent error, under the row of §9 for a
refused `session/new`. There is no usage-error row for `--cwd`. With no
`--cwd`, the binary sends its own working directory.

**Not every option shapes every subcommand.** The three subcommands take
one option group, because §6 gives them one grammar. What each option
then shapes is another matter, and each subcommand answers for itself.
Every option of the table above shapes `run`:

| Subcommand | The inert options | Why |
|---|---|---|
| `probe` | `--timeout` | `probe` runs no turn, and the limit bounds a turn. |
| `doctor` | `--cwd`, `--timeout`, `--verbose`, `--quiet` | `doctor` opens no session, so `--cwd` names nothing. It writes its whole report to stdout, and nothing of its own to stderr, so `--verbose` and `--quiet` shape nothing. Each of its rows keeps a time limit of its own, so `--timeout` is not that limit. |

`--frames` shapes all three. The check runner of `doctor` owns the frame
tee its rows read, so `doctor` hands it a sink for those frames, and the
runner calls the sink beside its own readings. The frames then reach
stderr, and the report on stdout is the same as without the flag.

An inert option is still parsed, and it is still checked. A `--timeout`
of zero or less gives the turn no time at all, so it is a usage error on
each of the three subcommands, and §9 exits it 2.

## 7. Where the prompt comes from

| Condition | Result |
|---|---|
| A prompt argument | Use it. |
| No prompt, and stdin is a pipe or a file | Read the prompt from stdin. |
| No prompt, and stdin is a terminal | Print the usage to stderr. Exit 2. |
| The prompt is `-` | Read the prompt from stdin, a terminal included. |

The agent's own stdin is a pipe that `AgentProcess` owns. It is never
this binary's stdin.

**The binary resolves a bare agent command itself.** It walks `PATH` in
order, and it takes the first entry that names an executable file. An
empty `PATH` entry is dropped: POSIX reads an empty entry as the working
directory, and a working directory on `PATH` is how a command in a
downloaded folder gets run by mistake.

The library does not do this, and that is deliberate.
`AgentProcess.init(command:)` refuses each command that does not start
with `/`, because a `PATH` lookup must select WHICH `PATH` applies, and a
library cannot answer that. A binary can: its `PATH` is the one its user
typed the command into. So the lookup lives in the binary, and every
value it hands `AgentProcess` is a value `AgentProcess` accepts. `run`,
`probe` and `doctor` share the one resolver, and the first check of the
§10 table reports its outcome.

## 8. stdout and stderr

- **stdout carries only the answer text.** Write each
  `agent_message_chunk` as it arrives, and flush it. Write the text
  verbatim: add no trailing newline, and add no color, in a terminal and
  in a pipe alike. The output is data, and a rule that changes with a
  terminal cannot be tested byte for byte.
- stdout gets nothing more. Not a session id, not a stop reason.
- `probe` and `doctor` are the exceptions. Their report **is** their
  output, so it goes to stdout.
- A default run writes nothing to stderr until it fails. `--verbose`
  writes the session events, one line each. `--frames` writes the
  messages. `--quiet` writes nothing but errors.
- When **stderr is a terminal**, and only then, show the running tool
  name on one line that is rewritten in place. A pipe or a file gets
  nothing.

A foreign agent may take a long time before its first answer chunk, and
we cannot know why: it may be downloading a model, as ours does. So when
stderr is a terminal, a plain spinner runs from the prompt until the
first chunk. It carries no claim about what the agent is doing.

**The turn ends on the `idle` `state_update`, and not on the prompt
acknowledgement.** In v2 a `PromptResponse` carries `meta` and nothing
more: it says the agent accepted the prompt, and it names no stop reason.
So the run reads the end of the turn off the `idle` update that comes
after it, and §9 reads the exit code off the stop reason that update
carries.

**The decline lines of §13.1 are the one exception** to "a default run
writes nothing to stderr until it fails". A run that refused a permission
request, or an elicitation, writes one line for each. Those lines go out
at every verbosity, `--quiet` included.

## 9. Exit codes

| Code | Meaning |
|---|---|
| 0 | `end_turn`, or a report that ran |
| 0 | An `idle` that reports NO stop reason. The schema makes the field optional, and an agent that went idle without a reason still went idle. |
| 0 | A stop reason this build does not know, which the generated `StopReason` carries as `unknown`. A turn that ended for a newer reason still ended. |
| 1 | An error: spawn, protocol, or I/O. `doctor` found an error. |
| 2 | A usage error |
| 3 | `refusal` |
| 4 | `cancelled` |
| 5 | `doctor` found warnings, and no error |
| 124 | A timeout, which is the `timeout(1)` convention |

This is the same table the agent CLI uses. Code 5 exists because the Rust
doctor's code 2 for errors would collide with the usage error. See
`doctor-plan.md` §5.

The three rows of code 0 are one rule: a turn that ENDED is a success,
whatever the agent said about why. A non-zero code for an unknown reason
would make each later addition to the schema look like a failure.

## 10. The `doctor` subcommand

`doctor` answers one question about a foreign agent: is it usable? The
protocol, the runner and the plain renderer come from Extras. This
package writes one `Doctorable` conformance over an agent command:

| Check | Catches |
|---|---|
| The command exists on `PATH`, or at the given path, and it is executable | A typing mistake, or a binary that was not built |
| The process starts, and it does not exit at once | A missing runtime, or a crash on start |
| It writes valid ndJSON, and nothing else, to stdout | An agent that prints a banner to stdout — the most common ACP defect |
| `initialize` answers inside a time limit | An agent that hangs |
| The protocol version is one we support | A v1 agent, or a newer draft |
| The `initialize` answer decodes, and no member of `capabilities` and no element of `authMethods` is dropped in silence | A malformed `initialize` result |
| The process ends when its stdin closes, and it leaves no child | A leaked agent |

The third row is worth the command on its own. `plan.md` for the agent
side makes "the agent MUST NOT write non-ACP content to stdout" a
protocol MUST, and a foreign agent that breaks it fails in a way that
looks like a parsing bug in **our** client.

Three rows make a decision the table alone does not show.

**Row 3 reads what `initialize` produced, and never what it hopes will
arrive.** A conformant ACP agent writes to stdout only in ANSWER to a
request. So a row that read stdout and waited for a line would wait for
ever against a CORRECT agent. Rows 3 and 4 are two rows and one exchange:
the doctor sends `initialize`, waits out its limit at most, and then
judges every whole line the agent wrote while that ran. A banner stands
ahead of the answer among those lines, so row 3 still catches it.

**Row 6 reads the RAW `initialize` answer, and never the decoded value.**
The generated `InitializeResponse` drops a member of the wrong shape, and
it throws nothing. A row that read the decoded value could therefore
never fail, and a check that cannot fail is not a check. So the row
decodes the raw answer itself and compares the two results. Only `info`
and `protocolVersion` can make the decode throw, and the row reports that
as an ERROR.

The row reads two members of the raw answer, `capabilities` and
`authMethods`, and there are three cases for each member. A member that
is absent, or that is `null`, is no loss: the schema lets an agent leave
each member out, and `null` is one way to write absent. A member of the
wrong shape is a WARNING that names the member, because the decode drops
the whole of it: a `capabilities` member that is not an object, or an
`authMethods` member that is not an array. A member of the correct shape
is compared with the decoded value. For `capabilities` the comparison is
by NAME: the row names each member that the raw object holds and the
decoded value does not. For `authMethods` the comparison is by COUNT
alone. `AuthMethod` is the wire's own union, and this package must not
spell what a correct element looks like. So an element that the raw
array holds and the decoded array does not is a dropped one, and the row
reports how many were dropped. Every loss stands on the one row, so a
person repairs the agent in one pass.

**Row 7 watches the process GROUP, and it runs BEFORE the teardown.**
`kill(pid, 0)` cannot tell an agent that runs from an unreaped zombie of
one, and an agent that leaves a child holds its own stdout open through
that child. `killpg(pid, 0)` asks the question the row means to ask: is
anything left. The row runs before the connection closes, because the
close of the connection group-kills the agent, and a row after that would
report `ok` against every agent — for the reason row 6 exists. The
verdict is a WARNING and never an error: such an agent answered every
request, so it is usable, and it leaks. §9 gives that verdict exit code
5, and this row is the reason that code exists.

`doctor` exits 0, 1 or 5 (§9). `--json` writes the report to stdout.

## 11. Interrupt and process ownership

`AgentProcess` already spawns the agent in its own process group, and it
vends the transport. This binary keeps those obligations, which `plan.md`
gives in "Transports, and who owns the agent process".

`Ctrl-C` must not kill the process at once. The binary sends
`session/cancel`, waits for the `cancelled` stop reason, prints the text
that arrived, reaps the agent, and exits 4. A second `Ctrl-C` ends the
run at once, and it still reaps the agent.

The `--timeout` limit of §6.1 and the `Ctrl-C` rule above are both
CHILDREN of the task group that runs the turn. Neither one races that
group from outside. A child that sleeps and then throws the timeout has
no race to lose: the group IS the race, the throw is the limit and
nothing else, and the group cancels and drains its other children on the
way out. So no task stays alive behind the exit.

**No agent process outlives the run.** This holds after success, after a
failure, after a timeout, and after an interrupt. A leaked agent holds
gigabytes of model weights, so a test asserts each path.

Each path is proven with a REAL pid. The stub agent writes its own pid to
a file, and the test reads that pid after the binary exits and asserts
`kill(pid, 0)` reports the process is gone. The map of the paths, and the
test that holds each one, stands on the kanban card ^f1fz3bv.

**The REAP itself is not proven from outside the run, and it cannot be.**
When a parent exits, the system gives its unreaped children to `launchd`,
which reaps them at once. So a pid read AFTER `acp-client` exits is gone
whether or not `acp-client` reaped it. The reap is proven where the
reader IS the parent and stays alive to read the pid:
`AgentProcessTests.killingAgentSurfacesDisconnectedState` kills the agent
that `AgentProcess` spawned from the test process, and then asserts the
pid is gone.

## 12. What this binary must not do

`plan.md` gives the import rule: "Never Router, ACPAgent, MCP, or the
FoundationModels framework." The two targets of §3 keep it.

The `acp-client` executable target links ONE thing: the `AcpClientCore`
library. It holds the `@main` type and nothing else, so it needs nothing
else.

`AcpClientCore` links FIVE things and nothing more: this package, the
wire, the family leaf `FoundationModelsExtras`, the parser and the
terminal package. The family leaf is one of the five because §10 builds
`doctor` on the Extras `Doctorable` module. §3 states the same count.
`ManifestTests` reads `Package.swift`, counts those five against the
library, and asserts that the executable takes the library alone.

## 13. Client capabilities

`plan.md` decides that `ACPClient.advertisedCapabilities` omits `auth`,
because `AgentProcess` spawns the agent on pipes and gives the user no
terminal. That decision holds for the container.

`acp-client` runs in a terminal, so it is the "host that owns a terminal"
that the decision mentions. It could build its own `ClientCapabilities`
value with `auth.terminal`.

**It does not do this in N1 to N6.** Terminal authentication needs the
binary to run the agent invocation again, in an interactive terminal, and
that is its own work. The first version advertises what the container
advertises. §16 holds the question.

### 13.1 Permission and elicitation

`acp-client` sends `ACPClient.advertisedCapabilities`. That value
advertises elicitation in both modes, so a foreign agent may send
`session/request_permission` or `elicitation/create` in the middle of the
one turn.

**The binary declines each one, and it writes one line to stderr for
each.** A permission request gets the request's own rejection option, or
the `cancelled` outcome when the request offers none. An elicitation gets
the `decline` action, in form mode and in url mode alike. No URL is
opened, and no value the agent asked for goes back over ACP.

The reason is the shape of the binary. A headless one-turn run has no
person to ask. The container holds such a request as observable state
until a UI answers it, and there is no UI here, so the turn would wait
for ever. And a batch run must never grant an agent something a person
did not see.

The decline line is what a reader needs. A run that refused an agent
something must say what it refused, or the person who reads the
transcript cannot tell a refusal from an answer the agent never asked
for. The line goes out at every verbosity, `--quiet` included, and §8
names it as the one exception to its stderr rule.

An INTERACTIVE `acp-client` needs a different answer, and §16 holds that
question.

## 14. Testing

| Test | Gate |
|---|---|
| The subcommand tree. `run`, `probe`, `doctor`, `--help`, `--version`. | none |
| A missing `--` gives a usage error and exit 2. stdout stays empty. | none |
| The agent arguments after `--` reach the agent unchanged, flags included. | none |
| The prompt-source table of §7, each row. | none |
| The stub agent over stdio: stdout is only the answer text, byte for byte. | none |
| `--frames` writes the messages to stderr, and stdout stays clean. | none |
| With stderr a pipe, a default run writes nothing to it. `--quiet` writes nothing in a terminal. | none |
| `probe` prints the stub agent's capabilities, and runs no turn. | none |
| `doctor` against a stub that writes a banner to stdout reports that row as an error. | none |
| `doctor` against a stub that never answers `initialize` reports a timeout, not a hang. | none |
| The stop reasons and the doctor statuses map to the exit codes of §9. | none |
| A timeout ends the run, and it reaps the agent. | none |
| An interrupt gives exit 4, and it reaps the agent. | none |
| No agent process outlives the run, in each exit path. | none |

Each row above is written, and each one is green. The stubs stand in two
places. The unit suite drives an in-process transport pair, and the
nested `IntegrationTests` package drives the built binary against shell
stubs. The two `doctor` stubs this table asks for — one that writes a
banner to stdout, and one that never answers — are among them.

The split of the two suites is structural. This package's manifest
declares no integration target, so `swift test` runs the unit tests and
nothing else. The other suite runs with
`swift test --package-path IntegrationTests`. CI runs both.

No model is necessary, and no network is necessary.

## 15. Milestones

| ID | Work | State |
|---|---|---|
| N1 | The target, the product, the `ArgumentParser` dependency, the subcommand tree, and the usage text. | Done |
| N2 | `run`: start the agent, run one turn, print the answer. §7 to §9. | Done |
| N3 | `--frames`. | Done |
| N4 | `probe`. | Done |
| N5 | `doctor` (§10). | Done |
| N6 | `--timeout`, the interrupt, and the tests of §11 that prove the reap. | Done |

N5 waited for two things, and both are behind it. The `Doctorable` module
of `FoundationModelsExtras` is written, its `main` branch is pushed, and
this package is resolved against it. No milestone of this plan now waits
for another package.

## 16. Open items

- **Terminal authentication.** Does `acp-client` advertise `auth.terminal`
  and re-run the agent invocation in the user's terminal? See §13. The
  answer needs a real agent that asks for it.
- **The interactive permission policy.** §13.1 makes a headless one-turn
  run decline each permission request and each elicitation. An
  INTERACTIVE `acp-client` needs another answer: a prompt the person
  reads, and a decision the person gives. What that prompt looks like,
  and which of the two elicitation modes it covers, is not decided.
- **More than one turn.** The binary runs one turn. A session that
  continues over several prompts is a different tool, and it is not in
  this plan.

## 17. Relation to the agent package

`FoundationModelsACPAgent` has its own `cli-plan.md`. It makes its
`acp-agent` binary a headless CLI and an ACP server, and it names
`acp-client` as the tool that tests its server mode over a real pipe:

```
acp-client run "write a haiku" --frames -- acp-agent acp
```

That test lives in the agent package, because this package must not
depend on the agent package. So this package publishes `acp-client` as an
executable product, and the agent package depends on it.

The two binaries must behave the same at the terminal, so five rules are
shared, and they say the same thing in both documents:

| Rule | Here | In the agent plan |
|---|---|---|
| The terminal package | §5 | §5.2 |
| Where the prompt comes from | §7 | §5.5 |
| stdout and stderr | §8 | §5.6, §5.7 |
| Exit codes | §9 | §5.8 |
| Interrupt | §11 | §5.9 |

A change to one of these five is a change to both documents.

**Order of the work:** `acp-client` must merge to `main` here before the
agent package can depend on it. The agent package declares its family
dependencies on the `main` branch, and not on a version.
