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
| Links | This package, `FoundationModelsACP`, `FoundationModelsExtras`, `ArgumentParser` and `Noora` |
| Path | `Sources/AcpClientCore/` |

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

It costs no new package checkout. `FoundationModelsExtras` already
declares `apple/swift-argument-parser` from 1.8.0, and this package
already depends on Extras, so the library stands in `Package.resolved`
today. `Package.swift` declares `apple/swift-argument-parser` directly,
with the same version floor, because the binary wants the parser only and
not the `Operations` fusion machinery that re-exports it.

## 5. The terminal output

The bar is a good Rust CLI. The agent plan adopts **Noora** (Tuist), a
Swift CLI design system that covers what indicatif, dialoguer,
comfy-table and owo-colors cover in Rust.

**This package follows that decision.** Two CLIs in one family that draw
tables differently is a defect a user sees.

It keeps the same containment rule: **one file imports Noora.**
`Sources/AcpClientCore/TerminalOutput.swift` vends a spinner, a
progress bar and a table, and every other file calls that type. A test
pins the single import over both source directories of §3, so a swap
costs one file.

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
| `--cwd <path>` | The working directory of the session. Default: the process working directory. |
| `--frames` | Write every ndJSON message to stderr, in both directions, with a direction mark. |
| `--timeout <seconds>` | End the run if the turn does not stop in time. Default: no limit. |
| `--verbose` | Write the session events to stderr. See §8. |
| `--quiet` | Draw no progress and no decoration, in a terminal too. |
| `--json` | `probe` and `doctor` only: write the report to stdout as JSON. |

`--frames` is the reason the binary exists. It shows the protocol
exchange, so a person can see what an agent sent.

## 7. Where the prompt comes from

| Condition | Result |
|---|---|
| A prompt argument | Use it. |
| No prompt, and stdin is a pipe or a file | Read the prompt from stdin. |
| No prompt, and stdin is a terminal | Print the usage to stderr. Exit 2. |
| The prompt is `-` | Read the prompt from stdin, a terminal included. |

The agent's own stdin is a pipe that `AgentProcess` owns. It is never
this binary's stdin.

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

## 9. Exit codes

| Code | Meaning |
|---|---|
| 0 | `end_turn`, or a report that ran |
| 1 | An error: spawn, protocol, or I/O. `doctor` found an error. |
| 2 | A usage error |
| 3 | `refusal` |
| 4 | `cancelled` |
| 5 | `doctor` found warnings, and no error |
| 124 | A timeout, which is the `timeout(1)` convention |

This is the same table the agent CLI uses. Code 5 exists because the Rust
doctor's code 2 for errors would collide with the usage error. See
`doctor-plan.md` §5.

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
| The advertised capabilities are readable | A malformed `initialize` result |
| The process ends when its stdin closes, and it leaves no child | A leaked agent |

The third row is worth the command on its own. `plan.md` for the agent
side makes "the agent MUST NOT write non-ACP content to stdout" a
protocol MUST, and a foreign agent that breaks it fails in a way that
looks like a parsing bug in **our** client.

`doctor` exits 0, 1 or 5 (§9). `--json` writes the report to stdout.

## 11. Interrupt and process ownership

`AgentProcess` already spawns the agent in its own process group, and it
vends the transport. This binary keeps those obligations, which `plan.md`
gives in "Transports, and who owns the agent process".

`Ctrl-C` must not kill the process at once. The binary sends
`session/cancel`, waits for the `cancelled` stop reason, prints the text
that arrived, reaps the agent, and exits 4. A second `Ctrl-C` ends the
run at once, and it still reaps the agent.

**No agent process outlives the run.** This holds after success, after a
failure, after a timeout, and after an interrupt. A leaked agent holds
gigabytes of model weights, so a test asserts each path.

## 12. What this binary must not do

`plan.md` gives the import rule: "Never Router, ACPAgent, MCP, or the
FoundationModels framework." The binary keeps it. It links this package,
the wire, the parser and the terminal package, and nothing more.

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
advertises. §15 holds the question.

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

The stub agent of the present suite serves each row. The `doctor` rows
need two more stubs: one that writes a banner to stdout, and one that
never answers. Both are a few lines.

No model is necessary, and no network is necessary.

## 15. Milestones

| ID | Work |
|---|---|
| N1 | The target, the product, the `ArgumentParser` dependency, the subcommand tree, and the usage text. |
| N2 | `run`: start the agent, run one turn, print the answer. §7 to §9. |
| N3 | `--frames`. |
| N4 | `probe`. |
| N5 | `doctor` (§10). Blocked by Extras D1 to D3. |
| N6 | `--timeout`, the interrupt, and the reaping tests of §11. |

N5 waits for the `Doctorable` module in Extras. Every other milestone is
free of an upstream block.

## 16. Open items

- **Terminal authentication.** Does `acp-client` advertise `auth.terminal`
  and re-run the agent invocation in the user's terminal? See §13. The
  answer needs a real agent that asks for it.
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
