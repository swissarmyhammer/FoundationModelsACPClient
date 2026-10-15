---
assignees:
- claude-code
depends_on:
- 01M4Z93G32SEN4MBR0W4NZVPP2
position_column: done
position_ordinal: fb80
title: 'T3: Remove the .timeLimit traits and each sleep, clock wait and poll in the tests'
---
Mail step 6, part T3 (mailbox.md section 8, row 6).

Remove the 43 .timeLimit traits and each sleep, clock wait and poll in Tests and IntegrationTests. Replace each one with a wait on an event (for example withObservationTracking on the model), a gate, or a fixed order.

Rules: STE text. No .timeLimit, sleep, clock wait, poll or retry. A clock may only measure and print time. A test that fails only sometimes is a bad test: find the cause and make it deterministic, or fix the race. Run the full suite one time; never run tests again and again to find a failure. If a test hangs, take a `sample <pid>` of your own test process before you stop it, and stop only your own process ids. Delete no test without a decision of the step owner. Commit after the task with ACPClient green. Report the commit, the test result and each difference from the plan with its reason. #mail-step-6