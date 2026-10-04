---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yrgnvfw3rz2wha98han0en
  text: 'Extra step (from foundationmodelsacp-c7, 2026-10-02): after this task is done and `swift build` gives no deprecation warnings for `SessionUpdateAggregator` or `updates(for:)`, send a message to the FoundationModelsACP session (foundationmodelsacp-c7): "ACPSessionState is gone; FoundationModelsACPClient no longer uses SessionUpdateAggregator or updates(for:)". That unblocks their task ^3wfc5m0, which removes both APIs.'
  timestamp: 2026-10-02T16:52:46.063507+00:00
- actor: claude-code
  id: 01m43h50hwwq320m6zmvadxbjh
  text: |
    ### Research (implement)

    Discoveries:
    - Old API: `ACPSessionState` (+Terminals: `terminal(for:)`, `AccumulatedTerminal.transcript`), `TurnState` (declared in ACPSessionState.swift, used only there), old `SessionEntry`, `SwiftUIACPClient` (+Connect). Only `ACPSessionState` uses `SessionUpdateAggregator`. No file uses `updates(for:)`.
    - `ChunkCoalescer`, `PatchField+Applied`, `PendingPermissionRequest`, `PendingElicitation`, `PendingRequestQueue`, `KeyedWaiters`, `ConnectionState` stay: the new models use them. Their doc comments name the old types; I update the comments.
    - `FoundationModelsACP.SessionEntry` is the merge-engine type of the wire package. The new models use it, so it stays. The acceptance search `SessionEntry\b` also finds that engine name; the old local type is the one to remove.
    - `DecliningClient`/`AgentSession` already use `ConnectionModel` (^hvqk65a).
    - `PermissionStubAgent` (in PermissionRequestTests.swift) is used only by the old tests. `drive(client:)`, the unit `waitForIdle(in: AsyncStream<SessionStreamEvent>)` and `promptTurnLandsReply(over:client:...)` are used only by the old tests.
    - `WireConformanceTests.everySessionUpdateCaseLandsInObservableStateOverTheWire` and `PermissionRequestTests.advertisedCapabilitiesMatchTheImplementedMethods` use the old container or live in an old file; I migrate them.
    - plan.md (not cli-plan.md) names `SwiftUIACPClient`. cli-plan.md names no removed type. There is no DocC catalog.

    ### Old test -> new test map

    SessionStateTests.swift:
    | old | new |
    |---|---|
    | userMessageChunkCreatesAUserEntryWithItsContent | SessionModelFoldTests.userMessageChunkAddsAUserMessageEntry |
    | agentMessageChunksAppendIntoOneInFlightMessage | SessionModelFoldTests.agentMessageChunksAppendToTheSameObject |
    | interleavedThoughtAndMessageChunksStaySeparate | SessionModelCoalescingTests.interleavedMessageAndThoughtChunksCoalesceIntoTheirOwnEntries, SessionModelFoldTests.agentThoughtChunkAddsAThoughtBesideTheMessageWithTheSameId |
    | wholeMessageUpsertReplacesAccumulatedContent | SessionModelFoldTests.agentMessageReplacesTheContentOfTheSameObject |
    | userMessageAndAgentThoughtUpsertsCreateTheirEntries | NEW SessionModelFoldTests.wholeUserMessageAndThoughtUpsertsAddTheirEntries |
    | toolCallUpdateLandsItsFullPayload | TranscriptEntryTests.toolCallUpdateCopiesEveryField |
    | toolCallUpdateForAKnownIdMutatesInsteadOfAppending | SessionModelFoldTests.toolCallUpdatesFoldIntoTheSameObject |
    | twoConcurrentSameNameToolCallsStayDistinct | NEW SessionModelFoldTests.twoToolCallsWithTheSameNameStayTwoEntries |
    | aToolCallUpdateForAnUnknownIdIsAdopted | SessionModelFoldTests.toolCallUpdatesFoldIntoTheSameObject (a status-only update of an unseen id adds the entry) |
    | toolCallContentChunkAppendsContentAndCreatesTheToolCall | SessionModelFoldTests.toolCallContentChunkAppendsContentToTheSameObject, NEW SessionModelFoldTests.toolCallContentChunkForAnUnseenIdAddsTheToolCall |
    | everyToolCallStatusValueLandsDistinctly | NEW SessionModelFoldTests.eachToolCallStatusLandsDistinctly |
    | stateUpdatesDriveTurnStateAndStopReason | SessionModelFoldTests.runningStateUpdateSetsTheAgentState, requiresActionStateUpdateReplacesTheAgentState, idleStateUpdateKeepsTheStopReason (the new model keeps the last `state_update` value; it does not carry an old stop reason forward, by design) |
    | planUpdateReplacesThePlanEntriesForItsPlanId | SessionModelFoldTests.planReplaceKeepsPosition |
    | availableCommandsUpdateReplacesTheCommandList | SessionModelFoldTests.availableCommandsUpdateSetsTheCommands, emptyAvailableCommandsUpdateGivesAnEmptyListNotNil |
    | anEmptyCommandListIsNotTheSameAsNoCommandListAtAll | SessionModelFoldTests.emptyAvailableCommandsUpdateGivesAnEmptyListNotNil |
    | configOptionUpdateReplacesTheConfigOptions | SessionModelFoldTests.configOptionUpdateSetsTheOptions |
    | sessionInfoUpdateFoldsTitleAndUpdatedAt | SessionModelFoldTests.sessionInfoUpdateFoldsAsAPatch |
    | usageUpdateLandsTheLatestUsage | SessionModelFoldTests.usageUpdateSetsTheUsage |
    | terminalUpdatesAccumulateOutputBytes | SessionModelFoldTests.terminalUpdateAddsATerminalEntry, terminalChunkAppendsBytes |
    | anUnknownUpdateChangesNoObservableState | SessionModelFoldTests.unknownUpdateBecomesUnknownEntry, NEW SessionModelFoldTests.anUnknownUpdateChangesNoOtherEntryAndNoAgentState |
    | entryIdentityIsStableAcrossUpdates | SessionModelFoldTests.agentMessageChunksAppendToTheSameObject, toolCallUpdatesFoldIntoTheSameObject, planReplaceKeepsPosition |
    | updatesForTwoSessionsLandInSeparateStates | NEW ConnectionModelSessionTests.updatesForTwoOpenSessionsLandInTheirOwnModels |
    | turnStateChangeTriggersObservation | SessionModelFoldTests.chunkForOneEntryFiresTheObservationOfThatEntry (observation of the model); the agent state is an `@Observable` stored property |
    | connectionStateIsObservableAndStartsDisconnected | ConnectionModelTests.aNewModelIsDisconnected, connectIsConnectedWhenItReturns |

    CoalescingTests.swift:
    | old | new |
    |---|---|
    | rapidChunksCauseFarFewerObservableMutationsThanChunks | SessionModelCoalescingTests.chunksInsideOneCadenceWriteTheEntryOneTime, chunksForANewEntryAppendTheTranscriptOneTime |
    | bufferedChunksFlushWhenTheCadenceElapses | SessionModelCoalescingTests.bufferedChunksWaitUntilTheCadenceElapses |
    | aTurnEndFlushesTheBufferedRemainderSynchronously | SessionModelCoalescingTests.aTurnEndFlushesTheBufferedRemainderSynchronously |
    | interleavedMessageAndThoughtChunksCoalesceIntoTheirOwnTargets | SessionModelCoalescingTests.interleavedMessageAndThoughtChunksCoalesceIntoTheirOwnEntries |
    | finalTextEqualsThePlainConcatenationOfAllChunks | SessionModelCoalescingTests.coalescedTextEqualsOneByOneApplication |
    | aConnectionCloseFlushesEveryBufferedSession | SessionModelStreamTests.closeFlushesTheBufferedChunks, NEW ConnectionModelTests.aDisconnectFlushesTheBufferedChunksOfEachOpenSession |

    RehydrationTests.swift:
    | old | new |
    |---|---|
    | anAccumulatingContainerIsStaleAfterCompactionAndAReloadingOneConverges | NEW SessionModelStreamTests.aReplayAfterACompactionGivesTheTranscriptOfAFreshReplay |
    | aMidSessionJoinerThatLoadsEqualsAFreshLoaderFieldForField | NEW SessionModelStreamTests.aReplayAfterACompactionGivesTheTranscriptOfAFreshReplay, NEW SessionModelStreamTests.aLiveStreamOfARecordGivesTheTranscriptOfItsReplay |
    | reloadingTwiceChangesNothing | SessionModelStreamTests.aSecondReplayGivesTheTranscriptOfOneReplay |
    | reloadWhileATurnStreamsKeepsTheInFlightMessageAndTheTurn | NEW SessionModelStreamTests.aLiveChunkAfterAReplayAppendsToTheReplayedMessage |
    | aPendingPermissionRequestSurvivesAReload | NEW SessionModelStreamTests.aPendingPermissionStaysPendingAcrossAReplay |
    | cancellingARehydrationKeepsThePriorStateAndLaterUpdatesApply | SessionModelStreamTests.aFailedReplayKeepsLiveHistory, isReplayingIsFalseAfterAFailedReplay, NEW SessionModelStreamTests.anUpdateAfterAFailedReplayApplies (the new model clears the transcript at the start of a replay, by design: aReplayIntoAModelWithATranscriptClearsTheLastValueState) |
    | aSessionResumeReplayOverTheWireRebuildsTheState | ConnectionModelSessionTests.resumeOfANewSessionRegistersAModelWithTheReplay, aSecondResumeOfAnOpenSessionGivesTheSameModelWithNoDoubledText |

    TerminalDisplayTests.swift:
    | old | new |
    |---|---|
    | interleavedChunksAccumulateTheConcatenatedBytesForEachTerminal | NEW SessionModelFoldTests.interleavedTerminalChunksAccumulateForEachTerminal |
    | snapshotOnTerminalUpdateReplacesTheAccumulatedOutput | SessionModelFoldTests.terminalOutputSnapshotReplacesBytes |
    | invalidBase64ChunkIsDroppedWithoutCorruptingTheOutput | NEW SessionModelFoldTests.aTerminalChunkThatIsNotBase64ChangesNoBytes |
    | invalidBase64SnapshotKeepsTheStoredOutput | NEW SessionModelFoldTests.aTerminalSnapshotThatIsNotBase64KeepsTheBytes |
    | nonUTF8BytesSurviveToTheReplacementCharacterTranscript | TranscriptEntryTests.terminalTextReplacesBadUTF8Bytes |
    | terminalUpdateForAnUnseenIdCreatesTheTerminal | SessionModelFoldTests.terminalUpdateAddsATerminalEntry, TranscriptEntryTests.terminalUpdateCopiesBytesExitStatusCommandAndDirectory |
    | terminalContentReferenceResolvesToItsTerminal | NEW SessionModelFoldTests.aTerminalReferenceOfAToolCallNamesTheIdOfItsTerminalEntry |
    | terminalContentReferenceToAnUnknownIdResolvesToNil | NEW SessionModelFoldTests.aTerminalReferenceToAnUnseenTerminalNamesNoEntry |

    PermissionRequestTests.swift:
    | old | new |
    |---|---|
    | answeringAPendingPermissionRequestResolvesTheAgentCallWithTheSelectedOption | SessionModelPendingTests.selectingAnOptionResolvesThePermissionWithThatOption |
    | cancellingTheAgentRequestClearsThePromptAndResumesTheContinuation | SessionModelPendingTests.cancellingTheAgentCallAnswersCancelledAndClearsThePermission |
    | cancellingFromTheUIAnswersCancelledAndClearsThePrompt | SessionModelPendingTests.cancellingFromTheUIAnswersCancelledAndClearsThePermission |
    | connectionDropWhilePendingClearsStateCleanly | ConnectionModelTests.aDisconnectClosesEachOpenSessionAndCancelsItsPendingPermission |
    | twoOverlappingRequestsStayPendingTogetherAndResolveIndependently | SessionModelPendingTests.twoOverlappingPermissionsResolveIndependently |
    | advertisedCapabilitiesMatchTheImplementedMethods | MOVED to ACPClientTests.advertisedCapabilitiesMatchTheImplementedMethods (it tests `ACPClient`, not the old container) |
    | aStubAgentsPermissionRequestRoundTripsOverTheWire | ModelClientTests.aPermissionRequestForAnOpenSessionLandsInItsModelAndTheChoiceReachesTheAgent |

    ElicitationTests.swift:
    | old | new |
    |---|---|
    | aFormElicitationAppearsAsPendingStateAndAcceptingResolvesTheAgentCall | SessionModelPendingTests.acceptingAFormElicitationResolvesWithAcceptAndTheValues |
    | decliningAPendingElicitationResolvesTheAgentCallWithDecline | SessionModelPendingTests.decliningAnElicitationResolvesWithDecline |
    | cancellingFromTheUIResolvesTheAgentCallWithCancel | SessionModelPendingTests.cancellingAnElicitationFromTheUIResolvesWithCancel |
    | cancellingTheAgentCallClearsThePendingElicitationAndResumesTheContinuation | SessionModelPendingTests.cancellingTheAgentCallResolvesTheElicitationWithCancel |
    | connectionDropWhilePendingClearsElicitationStateCleanly | ConnectionModelElicitationTests.aDisconnectCancelsEachRequestScopedElicitation, NEW ConnectionModelTests.aDisconnectCancelsEachSessionScopedElicitation |
    | aPendingUrlElicitationShowsTheTargetHostForTheConsentGate | SessionModelPendingTests.aPendingUrlElicitationShowsTheTargetHostForTheConsentGate |
    | elicitationCompleteClosesThePendingUrlPromptWithAcceptAndNoContent | SessionModelPendingTests.completingAUrlElicitationResolvesWithAcceptAndNoContent, ConnectionModelElicitationTests.aUrlElicitationCompleteClosesTheMatchingRequestScopedElicitation |
    | elicitationCompleteWithAnUnknownIdChangesNothing | SessionModelPendingTests.completingAnUnknownElicitationIdChangesNothing, ModelClientTests.anElicitationCompleteThatNoSessionHoldsLeavesEachPendingElicitation |
    | theSessionFilterReturnsSessionScopedElicitationsOnly | ModelClientTests.aSessionElicitationForAnOpenSessionLandsInItsModelAndTheAnswerReachesTheAgent, ConnectionModelElicitationTests.anElicitationDuringLoginIsPendingWithItsRequestIdAndMethod (a session-scoped elicitation lands on its SessionModel, a request-scoped one on the ConnectionModel; there is no filter now, by design) |
    | aStubAgentsFormElicitationRoundTripsOverTheWire | ModelClientTests.aSessionElicitationForAnOpenSessionLandsInItsModelAndTheAnswerReachesTheAgent |

    InProcessConnectionTests.swift:
    | old | new |
    |---|---|
    | fullSessionOverInMemoryPair | MIGRATED WireConformanceTests.everySessionUpdateCaseLandsInObservableStateOverTheWire (initialize, session/new, prompt, every update case, idle over the in-memory pair), ConnectionModelTests.connectIsConnectedWhenItReturns, aCloseByTheHostDisconnects |
    | hostCloseSurfacesDisconnectedState | ConnectionModelTests.aCloseByTheHostDisconnects |
    | aWrappingClientForwardsEveryUpdateIntoTheContainer | ConnectionModelTests.theConnectionServesTheClientThatTheWrapReturns, NEW ConnectionModelSessionTests.aWrapThatDropsEachUpdateLeavesTheTranscriptCurrent (each SessionModel reads its own subscription, so a wrapper cannot make the state stale) |
    | aWrapperThatAnswersPermissionKeepsTheContainerPromptEmpty | ConnectionModelTests.theConnectionServesTheClientThatTheWrapReturns |
    | hostCloseOnTheWrappingOverloadSurfacesDisconnectedState | ConnectionModelTests.aCloseByTheHostDisconnects (`connect(over:...:client:)` is one method; the wrap is a parameter with a default) |
    | theTwoArgumentConnectServesTheContainerItself | ConnectionModelTests.theConnectionServesTheRouterThatAnswersCancelled |
  timestamp: 2026-10-04T13:20:15.932050+00:00
- actor: claude-code
  id: 01m43hv4bj7wshxd5944yxrt5k
  text: |-
    ### Implementation notes

    - Correction to the map: the new wrapper test is `ConnectionModelSessionTests.aWrapThatForwardsEachCallKeepsTheTranscriptCurrent` (not `aWrapThatDropsEachUpdateLeavesTheTranscriptCurrent`). It follows the documented contract of `ConnectionModel.connect(...client:)`: a wrapper forwards each call. It proves the wrap runs one time, forwards each update, and the transcript gets the reply.
    - TDD: the new tests cover behavior that the new models already have (coverage migration), so each one passed on its first run except `WireConformanceTests.everySessionUpdateCaseLandsInObservableStateOverTheWire`. That run failed for a wrong assumption: the model holds the echo of a wire user message while a prompt waits for its response, so `user-1` is the last entry and not the first. The test now reads the set of wire identities.
    - `WireConformanceTests` now drives `ConnectionModel` + `SessionModel` through `ConnectedModel` and waits on the update tap. `ConnectedModel.init` got a `client` wrap parameter (default: the router).
    - The unit `TransportTestSupport.swift` now holds the integration form of `waitForIdle(in:)` (word for word); the old `promptTurnLandsReply(over:client:...)` is gone. Both headers list the same shared helpers, and name the helpers that only one copy holds.
    - New shared fixture `otherTestSession` in `SessionUpdateFixtures.swift`; `drive(client:)` is gone.
    - `advertisedCapabilitiesMatchTheImplementedMethods` moved to the new `ACPClientTests.swift`.
    - `TurnState` and the `AccumulatedTerminal.transcript` extension went away with `ACPSessionState` (no other user).
    - Acceptance search: `rg "ACPSessionState|SwiftUIACPClient|SessionEntry\b|SessionUpdateAggregator|hasReportedAvailableCommands" Sources Tests IntegrationTests README.md` finds only `FoundationModelsACP.SessionEntry` (and `SessionEntry.Compaction` in CompactionEntry.swift / SessionModelCompactionTests.swift), the merge-engine type of the wire package. That is a contract of FoundationModelsACP and cannot go. `rg "SessionUpdateAggregator|updates\(for:"` over Sources, Tests, IntegrationTests finds nothing.
    - I did not send a message to the FoundationModelsACP session; the orchestrator does that.

    ### implement — changed
    - evidence: deleted Sources/FoundationModelsACPClient/{ACPSessionState.swift, ACPSessionState+Terminals.swift, SessionEntry.swift, SwiftUIACPClient.swift, SwiftUIACPClient+Connect.swift} and Tests/FoundationModelsACPClientTests/{SessionStateTests, CoalescingTests, RehydrationTests, TerminalDisplayTests, PermissionRequestTests, ElicitationTests, InProcessConnectionTests}.swift; added Tests/FoundationModelsACPClientTests/ACPClientTests.swift; edited Sources ACPClient.swift, AgentProcess.swift, PendingElicitation.swift, PendingPermissionRequest.swift, Model/ChunkCoalescer.swift, Model/SessionModel+Coalescing.swift; Tests SessionUpdateFixtures.swift, TransportTestSupport.swift, WireConformanceTests.swift, Model/{ConnectedModel, ConnectionModelTests, ConnectionModelSessionTests, SessionModelFoldTests, SessionModelStreamTests, ChunkCoalescerTests, TranscriptEntryTests}.swift; IntegrationTests Support/TransportTestSupport.swift (header); README.md; plan.md. 21 new or migrated tests. `swift build --build-tests` (all sources touched): only the accepted MLX "missing creator" warning, no deprecation warning. `swift test`: 485 tests in 44 suites passed, 0 failures. `swift test --package-path IntegrationTests`: 103 tests in 14 suites passed, 0 failures. `rg "SessionUpdateAggregator|updates\(for:"` Sources Tests IntegrationTests: no match.
    - next: /review
  timestamp: 2026-10-04T13:32:20.722887+00:00
- actor: claude-code
  id: 01m43hvqd68d35md7v8hw29gyk
  text: |-
    ### orchestrator note — SessionEntry search
    The acceptance search was written to find our old `SessionEntry` type. That type had a name clash with the upstream `FoundationModelsACP.SessionEntry` (the merge-engine entry), and this task removes our type to end that clash. A match on the upstream `FoundationModelsACP.SessionEntry` is expected and correct. The criterion is met when the only `SessionEntry` matches are the upstream type.
  timestamp: 2026-10-04T13:32:40.230130+00:00
- actor: claude-code
  id: 01m43j030ngjnbh0zhqh9cqeja
  text: |-
    ### test — green
    - evidence: swift build --build-tests (root, full recompile) complete, only the accepted SwiftPM "missing creator for mutated node" warning; swift test (root) 485 tests in 44 suites passed; swift test --package-path IntegrationTests 103 tests in 14 suites passed; 0 failed, 0 skipped; grep finds no SessionUpdateAggregator or updates(for:) in any .swift file, and no deprecation warning in any output.
    - next: review
  timestamp: 2026-10-04T13:35:03.189595+00:00
- actor: claude-code
  id: 01m43j0j2m3rt4b4gkg97ze46t
  text: |-
    ### commit — changed
    - evidence: One local commit "refactor!: remove ACPSessionState, SessionEntry and SwiftUIACPClient". Its sha is in the final report of this step.
    - scope: Sources, Tests, IntegrationTests, README.md, plan.md and .kanban. Nothing under .build.
    - next: Review. The task did not move. Tests were green before this commit.
  timestamp: 2026-10-04T13:35:18.612897+00:00
- actor: claude-code
  id: 01m43jbk65s70z0efrwtkncwv5
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit a65af8a): 30 files reviewed, counts findings 0, confirmed 0, refuted 0. README.md and plan.md: no validator matches. The engine rule `code-hygiene/dead-code-swift` failed, because it writes to the damaged `.build` folder. I ran the same rule script by hand with `swift build --build-tests --scratch-path <scratchpad>/build` (build complete, only the accepted MLX "missing creator" warning) and `periphery scan --skip-build --index-store-path <scratchpad>/build/out`, with the test target `Tests/FoundationModelsACPClientTests` excluded as the rule does. The only results in product code are the three unused-module results in `Sources/FoundationModelsACPClient/Telemetry/ACPClientTelemetry.swift`. Commit a65af8a does not change that file, so these results are not on a changed line and are not findings of this diff review. The other `disallowed-constructs`, `function-length`, `idioms`, `magic-numbers` and `missing-docs` notes are about deleted files only. `.build` was not touched.
    - next: none. The task moved to done.
  timestamp: 2026-10-04T13:41:20.197960+00:00
- actor: claude-code
  id: 01m43jbyk10f2er5m768fqzt9s
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 36 files (5 Sources and 7 Tests deleted, 21 new coverage tests, README.md, plan.md)
    - test: green — swift test 485/485, IntegrationTests 103/103, no SessionUpdateAggregator / updates(for:) use and no deprecation warning (with --scratch-path)
    - commit: a65af8a refactor!: remove ACPSessionState, SessionEntry and SwiftUIACPClient
    - review: clean — task moved to done
  timestamp: 2026-10-04T13:41:31.873571+00:00
depends_on:
- 01M3YRF6NEW4C85GZ34DENNHYK
- 01M3YR27ERN3DKRHMA1C5TYWBR
- 01M3YR6VEEG5QGMKHKQ7JPV3JX
position_column: done
position_ordinal: d080
title: Remove ACPSessionState, SessionEntry, and SwiftUIACPClient; update the docs
---
## What
The old API does not need to be kept (decision of the user, through foundationmodelsacp-c7).

- [x] BEFORE any delete: add a comment on this task with a table that maps each test case of `SessionStateTests.swift`, `CoalescingTests.swift`, `RehydrationTests.swift`, `TerminalDisplayTests.swift`, `PermissionRequestTests.swift`, `ElicitationTests.swift`, `InProcessConnectionTests.swift` to the named new test that covers the same behavior. Write a new test for each case that has none.
- [x] Delete `Sources/FoundationModelsACPClient/ACPSessionState.swift`, `ACPSessionState+Terminals.swift`, `SessionEntry.swift`, `SwiftUIACPClient.swift`, `SwiftUIACPClient+Connect.swift` (its transport wrapper moved in task jge1qvf), and the seven old test files above.
- [x] Update the test helpers that name the old types: the `drive(client:)` helper in `Tests/FoundationModelsACPClientTests/SessionUpdateFixtures.swift`, and the `SwiftUIACPClient` helper in `Tests/FoundationModelsACPClientTests/TransportTestSupport.swift`.
- [x] Update the doc comments in `Sources/FoundationModelsACPClient/ACPClient.swift` and `Sources/FoundationModelsACPClient/AgentProcess.swift` that name `SwiftUIACPClient`.
- [x] Update `README.md` (usage example with `ConnectionModel` and `SessionModel`) and `plan.md` (sections "The container", "Rehydration", "Pending requests") in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] Each old test case has a named new test in the mapping comment.
- [x] `rg "ACPSessionState|SwiftUIACPClient|SessionEntry\b|SessionUpdateAggregator|hasReportedAvailableCommands" Sources Tests IntegrationTests README.md` finds nothing. (Note: the pattern `SessionEntry\b` also finds `FoundationModelsACP.SessionEntry`, the merge-engine type of the wire package that the new models use. That name is a contract of FoundationModelsACP and stays. The search finds no other match.)
- [x] `swift build` gives no warnings.

## Tests
- [x] `ForbiddenImportTests.swift` and `ManifestTests.swift` still pass.
- [x] `swift test` passes and `swift test --package-path IntegrationTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.