---
assignees:
- claude-code
position_column: todo
position_ordinal: 9c80
title: 'Decide what --cwd owes: SessionWorkingDirectoryError cannot be thrown'
---
## What

`AgentSession.SessionWorkingDirectoryError` is dead on every command line.

`AgentSession.sessionWorkingDirectory(for:)` builds the session directory as
`URL(fileURLWithPath: requested, relativeTo: processDirectory).standardizedFileURL`,
which is always an absolute path, and `AbsolutePath.init?(rawValue:)` refuses
only a string that does not start with `/`. So `absolutePath(_:)` never
returns `nil` for any `--cwd` value a person can type, and the error type it
throws has no reachable caller.

Found while sweeping every exit path of §11 (task ^f1fz3bv). The sweep looked
for the "--cwd does not resolve" exit path and there is none to sweep.

## The question this task answers

`cli-plan.md` §6.1 says `--cwd <path>` is "the working directory of the
session". A path that does not EXIST is passed to the agent unchecked today,
and the agent is left to fail on it. Two answers are open:

1. **The check is what is missing.** `--cwd` should reject a path that names
   no directory, with the usage row of §9. The error type then has a caller,
   and the message names the path the person typed.
2. **The check is not owed.** The session directory belongs to the AGENT, and
   an agent may hold a workspace this process cannot see. Then the error type
   is dead code and it goes, and §6.1 says so.

A person decides which. Do not guess.

## Acceptance Criteria

- [ ] The decision is recorded in `cli-plan.md` §6.1.
- [ ] Answer 1: `--cwd` is checked, the check has a unit test, and the error
      carries the path.
- [ ] Answer 2: `SessionWorkingDirectoryError` and `absolutePath(_:)` are
      deleted, and `openSession()` no longer says it throws them.
- [ ] Either way, no unreachable error type is left behind.

## Files

- `Sources/AcpClientCore/AgentSession.swift`
- `cli-plan.md` §6.1
