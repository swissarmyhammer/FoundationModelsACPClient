import Foundation
import FoundationModelsACP
import Observation
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// These tests drive the container through its `Client` conformance, one
// update case at a time, and read the observable state that each case must
// land.

/// The line number that the tool-call location test reports.
private let locationLine = 3

/// The context-window size that the usage test reports.
private let contextWindowSize = 200_000

/// The used-token count that the usage test reports.
private let usedTokens = 1_500

// MARK: - Message chunks and upserts

@MainActor @Test func userMessageChunkCreatesAUserEntryWithItsContent() async {
    let client = SwiftUIACPClient()

    await drive(client: client, userChunk(text: "hello"))

    let state = client.session(for: testSession)
    #expect(state.entries == [.userMessage(MessageId(rawValue: "user-1"))])
    #expect(state.messageContent(for: MessageId(rawValue: "user-1")) == [textBlock("hello")])
}

@MainActor @Test func agentMessageChunksAppendIntoOneInFlightMessage() async {
    let client = SwiftUIACPClient()

    await drive(client: client, agentChunk(text: "first "), agentChunk(text: "second"))

    let state = client.session(for: testSession)
    let messageID = MessageId(rawValue: "agent-1")
    #expect(state.entries == [.agentMessage(messageID)])
    #expect(state.messageContent(for: messageID) == [textBlock("first "), textBlock("second")])
    #expect(state.inFlightAgentMessageID == messageID)
}

@MainActor @Test func interleavedThoughtAndMessageChunksStaySeparate() async {
    let client = SwiftUIACPClient()

    await drive(
        client: client,
        thoughtChunk(text: "think-a"),
        agentChunk(text: "say-a"),
        thoughtChunk(text: "think-b"),
        agentChunk(text: "say-b")
    )

    let state = client.session(for: testSession)
    let thoughtID = MessageId(rawValue: "thought-1")
    let messageID = MessageId(rawValue: "agent-1")
    #expect(state.entries == [.agentThought(thoughtID), .agentMessage(messageID)])
    #expect(state.messageContent(for: thoughtID) == [textBlock("think-a"), textBlock("think-b")])
    #expect(state.messageContent(for: messageID) == [textBlock("say-a"), textBlock("say-b")])
    #expect(state.inFlightThoughtID == thoughtID)
    #expect(state.inFlightAgentMessageID == messageID)
}

@MainActor @Test func wholeMessageUpsertReplacesAccumulatedContent() async {
    let client = SwiftUIACPClient()
    let messageID = MessageId(rawValue: "agent-1")

    await drive(client: client, agentChunk(text: "draft"))
    await drive(
        client: client,
        .agentMessage(AgentMessage(messageId: messageID, content: .value([textBlock("final")])))
    )

    let state = client.session(for: testSession)
    #expect(state.entries == [.agentMessage(messageID)])
    #expect(state.messageContent(for: messageID) == [textBlock("final")])
}

@MainActor @Test func userMessageAndAgentThoughtUpsertsCreateTheirEntries() async {
    let client = SwiftUIACPClient()
    let userID = MessageId(rawValue: "user-9")
    let thoughtID = MessageId(rawValue: "thought-9")

    await drive(
        client: client,
        .userMessage(UserMessage(messageId: userID, content: .value([textBlock("question")]))),
        .agentThought(AgentThought(messageId: thoughtID, content: .value([textBlock("reasoning")])))
    )

    let state = client.session(for: testSession)
    #expect(state.entries == [.userMessage(userID), .agentThought(thoughtID)])
    #expect(state.messageContent(for: userID) == [textBlock("question")])
    #expect(state.messageContent(for: thoughtID) == [textBlock("reasoning")])
}

// MARK: - Tool calls

@MainActor @Test func toolCallUpdateLandsItsFullPayload() async {
    let client = SwiftUIACPClient()
    let callID = ToolCallId(rawValue: "call-1")
    let location = ToolCallLocation(path: AbsolutePath(rawValue: "/tmp/file.swift")!, line: locationLine)
    let update = ToolCallUpdate(
        toolCallId: callID,
        content: .value([.content(Content(content: textBlock("output")))]),
        kind: .value(.read),
        locations: .value([location]),
        rawInput: .value(.object(["path": .string("/tmp/file.swift")])),
        rawOutput: .value(.string("ok")),
        status: .value(.inProgress),
        title: .value("Read a file")
    )

    await drive(client: client, .toolCallUpdate(update))

    let state = client.session(for: testSession)
    #expect(state.entries == [.toolCall(callID)])
    let stored = state.toolCalls[callID]
    #expect(stored?.content == .value([.content(Content(content: textBlock("output")))]))
    #expect(stored?.kind == .value(.read))
    #expect(stored?.locations == .value([location]))
    #expect(stored?.rawInput == .value(.object(["path": .string("/tmp/file.swift")])))
    #expect(stored?.rawOutput == .value(.string("ok")))
    #expect(stored?.status == .value(.inProgress))
    #expect(stored?.title == .value("Read a file"))
}

@MainActor @Test func toolCallUpdateForAKnownIdMutatesInsteadOfAppending() async {
    let client = SwiftUIACPClient()
    let callID = ToolCallId(rawValue: "call-1")

    await drive(
        client: client,
        .toolCallUpdate(
            ToolCallUpdate(toolCallId: callID, status: .value(.pending), title: .value("Search"))
        ),
        toolCallStatus(id: "call-1", .completed)
    )

    let state = client.session(for: testSession)
    #expect(state.entries == [.toolCall(callID)])
    #expect(state.toolCalls[callID]?.status == .value(.completed))
    #expect(state.toolCalls[callID]?.title == .value("Search"))
}

@MainActor @Test func twoConcurrentSameNameToolCallsStayDistinct() async {
    let client = SwiftUIACPClient()
    let firstID = ToolCallId(rawValue: "call-1")
    let secondID = ToolCallId(rawValue: "call-2")

    await drive(
        client: client,
        .toolCallUpdate(
            ToolCallUpdate(toolCallId: firstID, status: .value(.inProgress), title: .value("shell"))
        ),
        .toolCallUpdate(
            ToolCallUpdate(toolCallId: secondID, status: .value(.inProgress), title: .value("shell"))
        ),
        toolCallStatus(id: "call-1", .completed)
    )

    let state = client.session(for: testSession)
    #expect(state.entries == [.toolCall(firstID), .toolCall(secondID)])
    #expect(state.toolCalls[firstID]?.status == .value(.completed))
    #expect(state.toolCalls[secondID]?.status == .value(.inProgress))
}

@MainActor @Test func aToolCallUpdateForAnUnknownIdIsAdopted() async {
    let client = SwiftUIACPClient()
    let callID = ToolCallId(rawValue: "call-unseen")

    // The id was never announced before. The documented behavior is to
    // adopt it: the first sighting creates the tool call.
    await drive(client: client, toolCallStatus(id: "call-unseen", .completed))

    let state = client.session(for: testSession)
    #expect(state.entries == [.toolCall(callID)])
    #expect(state.toolCalls[callID]?.status == .value(.completed))
}

@MainActor @Test func toolCallContentChunkAppendsContentAndCreatesTheToolCall() async {
    let client = SwiftUIACPClient()
    let callID = ToolCallId(rawValue: "call-1")

    await drive(
        client: client,
        .toolCallContentChunk(
            ToolCallContentChunk(content: .content(Content(content: textBlock("line-1"))), toolCallId: callID)
        ),
        .toolCallContentChunk(
            ToolCallContentChunk(content: .content(Content(content: textBlock("line-2"))), toolCallId: callID)
        )
    )

    let state = client.session(for: testSession)
    #expect(state.entries == [.toolCall(callID)])
    #expect(
        state.toolCalls[callID]?.content
            == .value([
                .content(Content(content: textBlock("line-1"))),
                .content(Content(content: textBlock("line-2"))),
            ])
    )
}

@MainActor @Test func everyToolCallStatusValueLandsDistinctly() async {
    let client = SwiftUIACPClient()
    let statuses: [String: ToolCallStatus] = [
        "call-pending": .pending,
        "call-running": .inProgress,
        "call-completed": .completed,
        "call-failed": .failed,
        "call-cancelled": .cancelled,
    ]

    for (id, status) in statuses {
        await drive(client: client, toolCallStatus(id: id, status))
    }

    let state = client.session(for: testSession)
    for (id, status) in statuses {
        #expect(state.toolCalls[ToolCallId(rawValue: id)]?.status == .value(status))
    }
    // A queued call and a running call must stay distinct states.
    #expect(
        state.toolCalls[ToolCallId(rawValue: "call-pending")]?.status
            != state.toolCalls[ToolCallId(rawValue: "call-running")]?.status
    )
}

// MARK: - Turn state

@MainActor @Test func stateUpdatesDriveTurnStateAndStopReason() async {
    let client = SwiftUIACPClient()
    let state = client.session(for: testSession)
    #expect(state.turnState == .idle)

    await drive(client: client, .stateUpdate(.running(RunningStateUpdate())))
    #expect(state.turnState == .running)

    await drive(client: client, .stateUpdate(.requiresAction(RequiresActionStateUpdate())))
    #expect(state.turnState == .awaitingInput)

    await drive(client: client, idleState(stopReason: .endTurn))
    #expect(state.turnState == .idle)
    #expect(state.lastStopReason == .endTurn)

    // An idle update without a stop reason keeps the last reported reason.
    await drive(client: client, .stateUpdate(.running(RunningStateUpdate())), idleState(stopReason: nil))
    #expect(state.turnState == .idle)
    #expect(state.lastStopReason == .endTurn)
}

// MARK: - Plans, commands, config, info, usage, terminals

@MainActor @Test func planUpdateReplacesThePlanEntriesForItsPlanId() async {
    let client = SwiftUIACPClient()
    let planID = PlanId(rawValue: "plan-1")
    let first = PlanEntry(content: "step one", priority: .medium, status: .pending)
    let second = PlanEntry(content: "step one", priority: .medium, status: .completed)

    await drive(client: client, .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: [first], planId: planID)))))
    #expect(client.session(for: testSession).plans[planID] == [first])

    await drive(client: client, .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: [second], planId: planID)))))
    #expect(client.session(for: testSession).plans[planID] == [second])
}

@MainActor @Test func availableCommandsUpdateReplacesTheCommandList() async {
    let client = SwiftUIACPClient()
    let command = AvailableCommand(description: "Makes a plan", name: "create_plan")

    await drive(client: client, .availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [command])))
    #expect(client.session(for: testSession).availableCommands == [command])

    await drive(client: client, .availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [])))
    #expect(client.session(for: testSession).availableCommands.isEmpty)
}

@MainActor @Test func configOptionUpdateReplacesTheConfigOptions() async {
    let client = SwiftUIACPClient()
    let option = SessionConfigOption(
        configId: SessionConfigId(rawValue: "mode"),
        name: "Mode",
        type: .boolean(SessionConfigBoolean(currentValue: true))
    )

    await drive(client: client, .configOptionUpdate(ConfigOptionUpdate(configOptions: [option])))

    #expect(client.session(for: testSession).configOptions == [option])
}

@MainActor @Test func sessionInfoUpdateFoldsTitleAndUpdatedAt() async {
    let client = SwiftUIACPClient()
    let state = client.session(for: testSession)

    await drive(
        client: client,
        .sessionInfoUpdate(SessionInfoUpdate(title: .value("Refactor"), updatedAt: .value("2026-08-18T00:00:00Z")))
    )
    #expect(state.title == "Refactor")
    #expect(state.updatedAt == "2026-08-18T00:00:00Z")

    // An omitted field keeps the stored value.
    await drive(client: client, .sessionInfoUpdate(SessionInfoUpdate(updatedAt: .value("2026-08-18T01:00:00Z"))))
    #expect(state.title == "Refactor")
    #expect(state.updatedAt == "2026-08-18T01:00:00Z")

    // An explicit null clears the stored value.
    await drive(client: client, .sessionInfoUpdate(SessionInfoUpdate(title: .cleared)))
    #expect(state.title == nil)
}

@MainActor @Test func usageUpdateLandsTheLatestUsage() async {
    let client = SwiftUIACPClient()
    let usage = UsageUpdate(size: contextWindowSize, used: usedTokens)

    await drive(client: client, .usageUpdate(usage))

    #expect(client.session(for: testSession).usage == usage)
}

@MainActor @Test func terminalUpdatesAccumulateOutputBytes() async {
    let client = SwiftUIACPClient()
    let terminalID = TerminalId(rawValue: "term-1")

    await drive(
        client: client,
        .terminalUpdate(TerminalUpdate(terminalId: terminalID, command: .value("ls"))),
        .terminalOutputChunk(
            TerminalOutputChunk(data: Data("first ".utf8).base64EncodedString(), terminalId: terminalID)
        ),
        .terminalOutputChunk(
            TerminalOutputChunk(data: Data("second".utf8).base64EncodedString(), terminalId: terminalID)
        )
    )

    let terminal = client.session(for: testSession).terminals[terminalID]
    #expect(terminal?.command == .value("ls"))
    #expect(terminal?.output == Data("first second".utf8))
}

// MARK: - Unknown updates

@MainActor @Test func anUnknownUpdateChangesNoObservableState() async {
    let client = SwiftUIACPClient()
    await drive(client: client, agentChunk(text: "hello"), idleState(stopReason: .endTurn))
    let state = client.session(for: testSession)
    let entriesBefore = state.entries

    await drive(client: client, .unknown("future_update", .object(["detail": .string("x")])))

    #expect(state.entries == entriesBefore)
    #expect(state.turnState == .idle)
    #expect(state.lastStopReason == .endTurn)
}

// MARK: - Entry identity

@MainActor @Test func entryIdentityIsStableAcrossUpdates() async {
    let client = SwiftUIACPClient()

    await drive(client: client, agentChunk(text: "a"), toolCallStatus(id: "call-1", .pending))
    let state = client.session(for: testSession)
    let identitiesBefore = state.entries.map(\.id)

    await drive(client: client, agentChunk(text: "b"), toolCallStatus(id: "call-1", .completed), thoughtChunk(text: "t"))

    let identitiesAfter = state.entries.map(\.id)
    #expect(Array(identitiesAfter.prefix(identitiesBefore.count)) == identitiesBefore)
    #expect(identitiesAfter.count == identitiesBefore.count + 1)
}

// MARK: - Sessions and the container

@MainActor @Test func updatesForTwoSessionsLandInSeparateStates() async {
    let client = SwiftUIACPClient()
    let otherSession = SessionId(rawValue: "session-2")

    await client.sessionUpdate(
        UpdateSessionNotification(sessionId: testSession, update: agentChunk(text: "one"))
    )
    await client.sessionUpdate(
        UpdateSessionNotification(sessionId: otherSession, update: agentChunk(text: "two", message: "agent-2"))
    )
    client.session(for: testSession).flushPendingChunks()
    client.session(for: otherSession).flushPendingChunks()

    #expect(client.sessions.count == 2)
    #expect(client.session(for: testSession).entries == [.agentMessage(MessageId(rawValue: "agent-1"))])
    #expect(client.session(for: otherSession).entries == [.agentMessage(MessageId(rawValue: "agent-2"))])
}

@MainActor @Test func turnStateChangeTriggersObservation() async {
    let client = SwiftUIACPClient()
    let state = client.session(for: testSession)
    let changed = Mutex(false)

    withObservationTracking {
        _ = state.turnState
    } onChange: {
        changed.withLock { $0 = true }
    }
    await drive(client: client, .stateUpdate(.running(RunningStateUpdate())))

    #expect(changed.withLock { $0 })
}

@MainActor @Test func connectionStateIsObservableAndStartsDisconnected() async {
    let client = SwiftUIACPClient()
    #expect(client.connectionState == .disconnected)
    let changed = Mutex(false)

    withObservationTracking {
        _ = client.connectionState
    } onChange: {
        changed.withLock { $0 = true }
    }
    client.connectionState = .connected

    #expect(client.connectionState == .connected)
    #expect(changed.withLock { $0 })
}

// MARK: - Permission

@MainActor @Test func requestPermissionAnswersCancelledUntilPendingStateLands() async throws {
    let client = SwiftUIACPClient()
    let request = RequestPermissionRequest(
        options: [
            PermissionOption(
                kind: .allowOnce,
                name: "Allow once",
                optionId: PermissionOptionId(rawValue: "allow-once")
            )
        ],
        sessionId: testSession,
        title: "Run the tool?"
    )

    let response = try await client.requestPermission(request)

    #expect(response.outcome == .cancelled)
}
