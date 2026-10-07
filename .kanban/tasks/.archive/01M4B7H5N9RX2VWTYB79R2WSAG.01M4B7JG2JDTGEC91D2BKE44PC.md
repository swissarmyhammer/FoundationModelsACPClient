---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4b7jft44ek56m595f4r27vh
  text: 'Archived during the /finish batch of 2026-10-07. This task repeats ^zws9qzt. Commit be7e615 ("chore(kanban): close task zws9qzt, because the MLX warnings are accepted") records that the user accepted the MLX "missing creator for mutated node" warning. The warning is not new; it comes from the mlx-swift dependency of FoundationModelsExtras. Unarchive this task only if the user decides to remove the warning after all.'
  timestamp: 2026-10-07T13:06:47.236278+00:00
position_column: todo
position_ordinal: '8e80'
title: The SwiftPM "missing creator for mutated node" warning for mlx-swift_Cmlx.bundle shows again in swift build and swift test
---
## What

`swift test` (and `swift build`) in this package writes this warning again:

```
warning: missing creator for mutated node: ('<package>/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')
```

A done task removed it before ("Remove the SwiftPM "missing creator for mutated node" warning that the MLX bundle of FoundationModelsExtras main causes in `swift build`"). Thus a later change, for example a new resolve of FoundationModelsExtras or of mlx-swift, brought it back. The source code of this package does not cause it. Found during the work on ^nzdk3m5 on 2026-10-07.

## Acceptance Criteria

- [ ] `swift build` and `swift test` show no `missing creator for mutated node` warning.
- [ ] The cause is recorded, so that a later resolve does not bring it back again.

## Tests

- Run `swift build` and `swift test` and read the output: zero warnings.
