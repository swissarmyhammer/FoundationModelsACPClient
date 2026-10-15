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
position_column: todo
position_ordinal: '80'
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