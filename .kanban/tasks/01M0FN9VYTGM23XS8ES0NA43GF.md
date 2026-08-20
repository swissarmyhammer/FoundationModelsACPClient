---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Fold the repo-local integration job into the shared swift-ci call
---
Blocked until the workflows-06 session lands the `integration-package-path` input on swissarmyhammer/workflows origin/main. The multitool session will message this session when it lands. Multitool's own conversion card is ^jjyqe1a in that repo — use it as the model.

The shape of the input, per the coordination message: the shared integration job builds and runs the nested package, the shared unit job builds it on every run, and the `needs: test` edge stays inside the shared workflow.

Steps when unblocked:
1. Verify the input landed: `git -C ../workflows fetch && git -C ../workflows show origin/main:.github/workflows/swift-ci.yaml`, read the input's exact name and semantics. Do not build on staged, unpushed work.
2. Update `.github/workflows/ci.yml`: pass the new input (value: `IntegrationTests`) on the existing shared call. Delete the repo-local "Integration (real agent subprocesses)" job. Update the header comment.
3. Update `Tests/FoundationModelsACPClientTests/CIWorkflowTests.swift`: the `needs: unit` edge it pins moves inside the shared workflow (`needs: test`), and our ci.yml no longer holds an integration job block. Re-point the test at what our ci.yml must then guarantee — the shared call passes the integration input — or port whatever pin multitool's conversion ships. Keep a pin; do not just delete the test.
4. Update the comments that name the repo-local job: `IntegrationTests/Package.swift` (the "compile coupling this package owes CI" section) and the root `Package.swift` note if needed.
5. Run root `swift test` and `swift test --package-path IntegrationTests` locally, commit, push, then verify a fresh CI run: the shared integration job must RUN (not skip) and be green, and the permanently-skipped row must be gone.

This resolves the skipped-row finding from card ^56dyr9f: our call will then opt the shared integration job in. #ci