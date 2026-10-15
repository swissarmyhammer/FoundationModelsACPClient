---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m506ht11ejfsdpmdpsxy7jbq
  text: |-
    ### session/resume: fixed. session/new: open, waits for a FoundationModelsACP hook.

    **Resume**
    - Fix: resumeInTurn registers a new model before the request goes out. On a failure, or when the connection changes, the model goes out of openSessions and is closed.
    - Red-first test: SessionOpenQuestionTests.aQuestionBeforeTheResumeAnswerIsPendingOnTheSessionModel. On the old code it failed in a fixed order: the agent got cancel, and no model was open.
    - Second test: the question at once after the resume answer is pending. On the fixed code its order is fixed, because the model is open before the request goes out. On the old code the result depends on timing, so it is not the red test.
    - Full run: 540 tests in 43 suites pass.

    **New (open race)**
    - newSession learns the session id only from the response, and it registers the model after the response.
    - A permission request or an elicitation that the agent sends at once after the session/new answer can reach ModelClient before the register. The client then answers cancel.
    - The step owner decided the fix: FoundationModelsACP gives ACPClient a synchronous hook on the reader, in frame order, when the response of newSession is decoded, with the new session id. ACPClient then marks "session X is opening". A routed request for X that misses waits until X is registered or its open failed. A request for each other unknown session gets cancel at once, as today.
    - No red test for new is in the suite yet. The order on the old code depends on timing, so a test of it fails only sometimes. A fixed-order red test needs the hook.
  timestamp: 2026-10-15T16:32:59.425128+00:00
- actor: claude-code
  id: 01m50741gngg3bmnfn81fsdccv
  text: |-
    ### Decision of the step owner
    - d321543 (the resume fix) is accepted.
    - Do not add an intermittent known-issue test for session/new. Such a test proves nothing.
    - Next: when the FoundationModelsACP hook exists, write the deterministic red test for session/new, and then the fix.
    - This card stays open until then.
  timestamp: 2026-10-15T16:42:56.917862+00:00
- actor: claude-code
  id: 01m50bjv118drq7js7txy38vbr
  text: |-
    ### session/new: fixed (option A of the step owner)
    - FoundationModelsACP is at fb55b2f, which has the hook newSession(_:onResponse:).
    - The hook marks the new session as opening in OpeningSessions, a Mutex store, on the reader in frame order. newSession ends the open in a defer: after the register, or after a failure.
    - The router (permission and session elicitation) calls ConnectionModel.openSession(waitingWhileOpening:). On a miss for an opening session, it waits until the open ends and reads again. A request for each other unknown session gets cancel at once, as before.
    - The internal test seam beforeRegisteringNewSession is nil outside the tests.
    - Red, then green: aQuestionThatReachesTheRouterBeforeTheNewSessionRegisterWaitsForIt holds the register until the routed question waits.
      - With the seam and no hold, it failed in a fixed order: cancel, nothing pending.
      - With the hold, it passes.
    - The one-write wire test is an end-to-end check. Its doc says that it does not prove the order. In one run with no hold, it failed too, which shows the race.
    - Found on the way: ^tnf8rmm (session(for:) was not observed while a session is not open). That card is fixed and done.
    - Full run: 542 tests in 43 suites pass. IntegrationTests builds.
  timestamp: 2026-10-15T18:00:56.097398+00:00
position_column: done
position_ordinal: fe80
title: 'Defect: a request of the agent at once after session/resume or session/new gets cancel, because the model registers the session too late'
---
From AgentViewKit step 7 (^4tw540d), in ACPClient 838bbad.

ConnectionModel.resumeSession registers a new SessionModel only after the resume response and the replay (ConnectionModel+Sessions.swift:159). newSession registers only after the response (:67). The agent can send session/request_permission or elicitation/create at once after the result. The handler of ModelClient then can run before the register: session(for:) gives nil, and the client answers cancel. The request is never pending.

Do:
1. Confirm the cause with fixed-order tests that fail on the old code.
2. Fix it with no clock: register before the response is handled, or hold the routed request until the register.
3. Check session/new for the same race (session/load does not exist in ACP v2).
4. One full run, push, CI.

#defect