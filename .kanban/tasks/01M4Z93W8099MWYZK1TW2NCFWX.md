---
assignees:
- claude-code
depends_on:
- 01M4Z93NR2EGCQRYVA5YHJSKJ2
position_column: todo
position_ordinal: '8480'
title: 'T4: Docs agree with the new behavior; final run, live test, final report'
---
Mail step 6, part T4 (mailbox.md section 8, row 6).

Make the docs and comments (README, DocC, doc comments) agree with the new ACPAgent wire behavior. Then:
- one full suite run;
- the live test one time, only if the models are complete in the local cache (check first; do not download in a test run);
- the final commit;
- the final report with the list of commits and the check of row 6: "The live test passes against the new ACPAgent."

Push when step 6 is green, and report the head and CI.

Rules: STE text. Run the full suite one time; never run tests again and again to find a failure. Stop only your own process ids. #mail-step-6