import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// These tests cover milestone M4: rehydration. The agent's record is not
// monotonic. Compaction rewrites the record, and entries that this
// container showed can stop to exist. Thus the container must be able to
// rebuild its full state from a `session/resume` replay, and must not
// only accumulate.

/// The id of the summary message that compaction writes into the record.
private let summaryMessageID = MessageId(rawValue: "summary-1")

/// The id of the user message of the second turn.
private let secondUserMessageID = MessageId(rawValue: "user-2")

/// The id of the agent message of the second turn.
private let secondAgentMessageID = MessageId(rawValue: "agent-2")

/// The command that the replay announces.
private let replayCommand = AvailableCommand(description: "Makes a plan", name: "create_plan")

/// Makes the live updates of the first turn, before compaction.
///
/// - Returns: The updates, in order.
private func firstTurnLiveUpdates() -> [SessionUpdate] {
    [
        userChunk(text: "first question", message: "user-1"),
        agentChunk(text: "first answer", message: "agent-1"),
        idleState(stopReason: .endTurn),
    ]
}

/// Makes the live updates of the second turn, after compaction.
///
/// - Returns: The updates, in order.
private func secondTurnLiveUpdates() -> [SessionUpdate] {
    [
        userChunk(text: "second question", message: secondUserMessageID.rawValue),
        agentChunk(text: "second answer", message: secondAgentMessageID.rawValue),
        idleState(stopReason: .endTurn),
    ]
}

/// Makes the replay that a `session/resume` call streams after compaction.
///
/// The record holds one summary message in place of the first turn, and
/// holds the full second turn. The agent message of the second turn
/// replays as two chunks, so a replay that lands two times shows
/// two-time content in a container that only accumulates.
///
/// - Returns: The replayed updates, in order.
private func compactedRecordReplay() -> [SessionUpdate] {
    [
        .agentMessage(
            AgentMessage(
                messageId: summaryMessageID,
                content: .value([textBlock("summary of the first turn")])
            )
        ),
        .userMessage(
            UserMessage(
                messageId: secondUserMessageID,
                content: .value([textBlock("second question")])
            )
        ),
        agentChunk(text: "second ", message: secondAgentMessageID.rawValue),
        agentChunk(text: "answer", message: secondAgentMessageID.rawValue),
        toolCallStatus(id: "call-1", .completed),
        .availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [replayCommand])),
        .sessionInfoUpdate(SessionInfoUpdate(title: .value("Compacted session"))),
        idleState(stopReason: .endTurn),
    ]
}

/// Sends each update to the client for the test session, with no flush.
///
/// - Parameters:
///   - updates: The updates to send, in order.
///   - client: The client under test.
@MainActor
private func send(_ updates: [SessionUpdate], to client: SwiftUIACPClient) async {
    for update in updates {
        await client.sessionUpdate(
            UpdateSessionNotification(sessionId: testSession, update: update)
        )
    }
}

/// Streams each update to the client for the test session, and flushes the
/// coalescing buffer at the end, so assertions read landed state.
///
/// - Parameters:
///   - updates: The updates to stream, in order.
///   - client: The client under test.
@MainActor
private func stream(_ updates: [SessionUpdate], into client: SwiftUIACPClient) async {
    await send(updates, to: client)
    client.session(for: testSession).flushPendingChunks()
}

/// Rebuilds the test session of the client from a replay.
///
/// The call brackets the replayed updates with `beginRehydration()` and
/// `endRehydration()`, in the same shape a host uses around a
/// `session/resume` call.
///
/// - Parameters:
///   - client: The client under test.
///   - replay: The replayed updates, in order.
@MainActor
private func rehydrate(client: SwiftUIACPClient, replay: [SessionUpdate]) async {
    let state = client.session(for: testSession)
    state.beginRehydration()
    await send(replay, to: client)
    state.endRehydration()
}

/// Compares two session states, field for field.
///
/// - Parameters:
///   - lhs: One session state.
///   - rhs: The other session state.
@MainActor
private func expectEqualState(_ lhs: ACPSessionState, _ rhs: ACPSessionState) {
    #expect(lhs.entries == rhs.entries)
    #expect(lhs.inFlightAgentMessageID == rhs.inFlightAgentMessageID)
    #expect(lhs.inFlightThoughtID == rhs.inFlightThoughtID)
    #expect(lhs.availableCommands == rhs.availableCommands)
    #expect(lhs.configOptions == rhs.configOptions)
    #expect(lhs.title == rhs.title)
    #expect(lhs.updatedAt == rhs.updatedAt)
    #expect(lhs.usage == rhs.usage)
    #expect(lhs.turnState == rhs.turnState)
    #expect(lhs.lastStopReason == rhs.lastStopReason)
    #expect(lhs.toolCalls == rhs.toolCalls)
    #expect(lhs.plans == rhs.plans)
    #expect(lhs.terminals == rhs.terminals)
    for entry in lhs.entries {
        if case .message(let messageID) = entry.id {
            #expect(lhs.messageContent(for: messageID) == rhs.messageContent(for: messageID))
        }
    }
}

@MainActor @Test func anAccumulatingContainerIsStaleAfterCompactionAndAReloadingOneConverges() async {
    // The fresh loader sees only the post-compaction record.
    let freshLoader = SwiftUIACPClient()
    await rehydrate(client: freshLoader, replay: compactedRecordReplay())

    // The accumulating container streamed both turns and never reloads.
    let accumulating = SwiftUIACPClient()
    await stream(firstTurnLiveUpdates(), into: accumulating)
    await stream(secondTurnLiveUpdates(), into: accumulating)

    // The accumulating container is stale: it shows entries that the
    // record no longer holds, and it does not show the summary.
    let accumulatingState = accumulating.session(for: testSession)
    #expect(accumulatingState.entries.contains(.userMessage(MessageId(rawValue: "user-1"))))
    #expect(accumulatingState.entries.contains(.agentMessage(MessageId(rawValue: "agent-1"))))
    #expect(!accumulatingState.entries.contains(.agentMessage(summaryMessageID)))
    #expect(accumulatingState.entries != freshLoader.session(for: testSession).entries)

    // The reloading container streamed the same turns, then reloads. It
    // converges on the post-compaction record.
    let reloading = SwiftUIACPClient()
    await stream(firstTurnLiveUpdates(), into: reloading)
    await stream(secondTurnLiveUpdates(), into: reloading)
    await rehydrate(client: reloading, replay: compactedRecordReplay())

    expectEqualState(
        reloading.session(for: testSession),
        freshLoader.session(for: testSession)
    )
}

@MainActor @Test func aMidSessionJoinerThatLoadsEqualsAFreshLoaderFieldForField() async {
    let replay = compactedRecordReplay()

    // The fresh loader starts empty and loads the record.
    let freshLoader = SwiftUIACPClient()
    await rehydrate(client: freshLoader, replay: replay)

    // The joiner streamed only a suffix of the session, then loads.
    let joiner = SwiftUIACPClient()
    await stream(secondTurnLiveUpdates(), into: joiner)
    await rehydrate(client: joiner, replay: replay)

    // A container that streamed the same updates from the start, with no
    // compaction, reaches the same state as well.
    let streamer = SwiftUIACPClient()
    await stream(replay, into: streamer)

    expectEqualState(joiner.session(for: testSession), freshLoader.session(for: testSession))
    expectEqualState(streamer.session(for: testSession), freshLoader.session(for: testSession))
}

@MainActor @Test func reloadingTwiceChangesNothing() async {
    let replay = compactedRecordReplay()

    let reloadedOnce = SwiftUIACPClient()
    await stream(secondTurnLiveUpdates(), into: reloadedOnce)
    await rehydrate(client: reloadedOnce, replay: replay)

    let reloadedTwice = SwiftUIACPClient()
    await stream(secondTurnLiveUpdates(), into: reloadedTwice)
    await rehydrate(client: reloadedTwice, replay: replay)
    await rehydrate(client: reloadedTwice, replay: replay)

    expectEqualState(
        reloadedTwice.session(for: testSession),
        reloadedOnce.session(for: testSession)
    )
}

@MainActor @Test func reloadWhileATurnStreamsKeepsTheInFlightMessageAndTheTurn() async {
    let client = SwiftUIACPClient()
    let state = client.session(for: testSession)

    // A turn is in progress. The last chunks stay in the coalescing
    // buffer, with no flush, when the reload starts.
    await stream(
        [
            userChunk(text: "question", message: "user-1"),
            .stateUpdate(.running(RunningStateUpdate())),
        ],
        into: client
    )
    await send(
        [
            agentChunk(text: "Hel", message: "agent-1"),
            agentChunk(text: "lo", message: "agent-1"),
        ],
        to: client
    )

    // The agent replays the record of the turn so far, then the live
    // stream continues.
    await rehydrate(
        client: client,
        replay: [
            .userMessage(
                UserMessage(messageId: MessageId(rawValue: "user-1"), content: .value([textBlock("question")]))
            ),
            agentChunk(text: "Hel", message: "agent-1"),
            agentChunk(text: "lo", message: "agent-1"),
            .stateUpdate(.running(RunningStateUpdate())),
        ]
    )
    await stream([agentChunk(text: " world", message: "agent-1")], into: client)

    // The in-flight message holds the replayed prefix plus the live
    // suffix, one time each. The turn is still running.
    let messageID = MessageId(rawValue: "agent-1")
    #expect(
        state.messageContent(for: messageID)
            == [textBlock("Hel"), textBlock("lo"), textBlock(" world")]
    )
    #expect(state.entries == [.userMessage(MessageId(rawValue: "user-1")), .agentMessage(messageID)])
    #expect(state.inFlightAgentMessageID == messageID)
    #expect(state.turnState == .running)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPendingPermissionRequestSurvivesAReload() async throws {
    let client = SwiftUIACPClient()
    let request = RequestPermissionRequest(
        options: [
            PermissionOption(
                kind: .allowOnce,
                name: "Allow",
                optionId: PermissionOptionId(rawValue: "allow-once")
            )
        ],
        sessionId: testSession,
        title: "Run the tool?"
    )

    let responseTask = Task { try await client.requestPermission(request) }
    let state = client.session(for: testSession)
    while state.pendingPermissionRequests.isEmpty {
        try Task.checkCancellation()
        await Task.yield()
    }

    // The pending request is live request state, not record state. It
    // stays pending across a reload.
    state.beginRehydration()
    #expect(state.isRehydrating)
    await send(compactedRecordReplay(), to: client)
    state.endRehydration()
    #expect(!state.isRehydrating)
    #expect(state.pendingPermissionRequests.count == 1)

    // The answer still resolves the agent's in-flight call.
    let pending = try #require(state.pendingPermissionRequests.first)
    state.answerPermissionRequest(pending.id, with: PermissionOptionId(rawValue: "allow-once"))
    let response = try await responseTask.value
    #expect(
        response.outcome
            == .selected(SelectedPermissionOutcome(optionId: PermissionOptionId(rawValue: "allow-once")))
    )
    #expect(state.pendingPermissionRequests.isEmpty)
}

@MainActor @Test func cancellingARehydrationKeepsThePriorStateAndLaterUpdatesApply() async {
    let client = SwiftUIACPClient()
    let state = client.session(for: testSession)
    await stream(secondTurnLiveUpdates(), into: client)
    let entriesBefore = state.entries

    // The capture starts. The observable state stays at the prior
    // values while the replay streams, so a UI never shows an empty
    // intermediate state.
    state.beginRehydration()
    #expect(state.isRehydrating)
    await send([userChunk(text: "replayed", message: "user-9")], to: client)
    #expect(state.entries == entriesBefore)

    // The load failed. The cancel discards the capture and keeps the
    // prior state.
    state.cancelRehydration()
    #expect(!state.isRehydrating)
    #expect(state.entries == entriesBefore)
    #expect(state.messageContent(for: MessageId(rawValue: "user-9")).isEmpty)

    // Later live updates apply normally.
    await stream([userChunk(text: "third question", message: "user-3")], into: client)
    #expect(state.entries == entriesBefore + [.userMessage(MessageId(rawValue: "user-3"))])
}

/// A stub agent whose record compacts between its two prompt turns.
///
/// The first prompt streams the first turn. The second prompt streams the
/// second turn. Between the two prompts, the stub compacts its record:
/// the record then holds one summary message plus the second turn.
/// `resumeSession` replays that record.
private actor CompactingStubAgent: Agent {
    /// The connection back to the client.
    private let connection: AgentSideConnection

    /// The count of prompt calls, so the stub knows which turn to stream.
    private var promptedTurnCount = 0

    /// Creates the stub.
    ///
    /// - Parameter connection: The connection back to the client.
    init(connection: AgentSideConnection) {
        self.connection = connection
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "compacting-stub-agent", version: "1.0.0"),
            protocolVersion: params.protocolVersion
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        throw RequestError.methodNotFound("session/new")
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        throw RequestError.methodNotFound("session/list")
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        try await sendToClient(compactedRecordReplay())
        return ResumeSessionResponse()
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        throw RequestError.methodNotFound("session/close")
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        promptedTurnCount += 1
        let updates = promptedTurnCount == 1 ? firstTurnLiveUpdates() : secondTurnLiveUpdates()
        try await sendToClient(updates)
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}

    /// Sends each update over the wire, for the test session.
    ///
    /// - Parameter updates: The updates to send, in order.
    private func sendToClient(_ updates: [SessionUpdate]) async throws {
        for update in updates {
            try await connection.sessionUpdate(
                UpdateSessionNotification(sessionId: testSession, update: update)
            )
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aSessionResumeReplayOverTheWireRebuildsTheState() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let model = SwiftUIACPClient()
    let connection = await ClientSideConnection(stream: clientEnd) { _ in model }
    let agentConnection = await AgentSideConnection(stream: agentEnd) { agentSide in
        CompactingStubAgent(connection: agentSide)
    }

    // The stub streams both turns. Its record compacts between them, so
    // the accumulated state is now stale against the record.
    _ = try await connection.prompt(PromptRequest(prompt: [textBlock("go")], sessionId: testSession))
    _ = try await connection.prompt(PromptRequest(prompt: [textBlock("go")], sessionId: testSession))
    let state = model.session(for: testSession)
    state.flushPendingChunks()
    #expect(state.entries.contains(.agentMessage(MessageId(rawValue: "agent-1"))))
    #expect(!state.entries.contains(.agentMessage(summaryMessageID)))

    // The reload brackets a real `session/resume` call. The rebuilt state
    // equals the state of a fresh loader of the same record.
    state.beginRehydration()
    _ = try await connection.resumeSession(
        ResumeSessionRequest(
            cwd: AbsolutePath(rawValue: "/")!,
            sessionId: testSession,
            replayFrom: .start(ReplayFromStart())
        )
    )
    state.endRehydration()

    let freshLoader = SwiftUIACPClient()
    await rehydrate(client: freshLoader, replay: compactedRecordReplay())
    expectEqualState(state, freshLoader.session(for: testSession))

    await connection.close()
    withExtendedLifetime(agentConnection) {}
}
