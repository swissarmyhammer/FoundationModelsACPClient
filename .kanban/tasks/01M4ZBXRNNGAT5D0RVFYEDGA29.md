---
assignees:
- claude-code
position_column: done
position_ordinal: f980
title: 'Reap: wait on the exit event or the reap limit on an injected clock, with no poll'
---
Decision A of mail step 6, from the step owner. AgentProcessState.reap(pid:) arms a kqueue exit source, checks one time with WNOHANG, and then waits for the first of two events: the exit event, then one waitpid; or the reap limit on an injected clock (internal, default ContinuousClock). The WNOHANG loop and Thread.sleep are gone. The teardown tests use a manual clock and no wall time: "reaps when the child exits", and "returns when the limit passes" in a fixed order. No test is deleted. #mail-step-6