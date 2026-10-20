---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: The SwiftPM warning "missing creator for mutated node" for mlx-swift_Cmlx.bundle came back
---
Found during ^jebhkm3.

`swift test` in the root package and `swift build --build-tests` in `IntegrationTests` show this line:

`warning: missing creator for mutated node: ('.../.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`

The card 01M3Z8M7YKRR5TQ5NRPZWS9QZT removed this warning before. It is in `done`, but the warning is in the build again. The cards ^yvrk73p and ^jebhkm3 record it too. No source file of this package causes it: the MLX bundle comes from a dependency (FoundationModelsExtras).

## Acceptance criteria
- [ ] Find which dependency revision brought the warning back.
- [ ] `swift build`, `swift test` and `swift build --build-tests --package-path IntegrationTests` show zero warnings.