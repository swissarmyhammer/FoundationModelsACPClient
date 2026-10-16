import FoundationModelsACP
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// These tests drive the connection model and the session model over the real
// ACP wire, in the order of FoundationModelsACPAgent 293be4b: a prompt is
// mail, its `session/prompt` answer comes at once, and each update comes
// after that answer. `running` and `idle` come from the work of the agent,
// also when no prompt is open, and an `idle` can have no stop reason.
//
// Each test fixes the order: the test sends each update itself through
// `MailOrderStubAgent`, and waits on the observable state of the model. No
// test waits on a clock.

/// The message id of the first prompt of a test, as the agent gives it: the
/// mail id of Router, a ULID string.
private let firstMessageId = MessageId(rawValue: "01K7Z9ACPCL1ENTMA1L0RDER01")

/// The message id of the second prompt of a test.
private let secondMessageId = MessageId(rawValue: "01K7Z9ACPCL1ENTMA1L0RDER02")

/// A connection model that is connected over an in-memory pair to a
/// ``MailOrderStubAgent``, with one open session.
@MainActor
private struct MailOrderSession {
    /// The model under test.
    let model: ConnectionModel

    /// The agent-side connection. The test holds it so that the agent end of
    /// the pair outlives the test body.
    let agentConnection: AgentSideConnection

    /// The stub agent.
    let agent: MailOrderStubAgent

    /// The open session.
    let session: SessionModel

    /// Connects a model, initializes it, and opens one session.
    ///
    /// - Parameter messageIds: The message id of each prompt answer, in
    ///   order.
    /// - Throws: The error of `initialize` or of `session/new`.
    init(messageIds: [MessageId]) async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let built = Mutex<MailOrderStubAgent?>(nil)
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            let stub = MailOrderStubAgent(connection: connection, messageIds: messageIds)
            built.withLock { $0 = stub }
            return stub
        }
        model = ConnectionModel(coalescingCadence: .zero)
        _ = await model.connect(over: clientEnd)
        _ = try await model.initialize(makeInitializeRequest())
        session = try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: "/")))
        agent = try #require(built.withLock { $0 })
    }

    /// The user messages of the transcript, in transcript order.
    var userMessages: [UserMessageEntry] {
        session.transcript.compactMap(\.userMessage)
    }

    /// The text of each agent message of the transcript, joined.
    var agentText: String {
        session.transcript.compactMap(\.agentMessage).flatMap(\.content).compactMap { block in
            guard case .text(let content) = block else { return nil }
            return content.text
        }.joined()
    }
}

/// Makes the echo of a user message, as the agent sends it after the answer.
///
/// - Parameters:
///   - messageId: The message id that the prompt answer gave.
///   - text: The text of the prompt.
/// - Returns: The update.
private func echo(_ messageId: MessageId, text: String) -> SessionUpdate {
    .userMessage(UserMessage(messageId: messageId, content: .value([textBlock(text)])))
}

/// The `running` state update.
private let running = SessionUpdate.stateUpdate(.running(RunningStateUpdate()))

@MainActor
struct SessionModelMailOrderTests {
    /// G2: the answer comes first, then the echo, `running`, the answer text
    /// and `idle`. The local user message links by the message id of the
    /// answer, and the echo adds no second entry.
    @Test func aPromptLinksByTheMessageIdOfItsAnswerAndItsEchoAfterTheAnswerAddsNoEntry() async throws {
        let connected = try await MailOrderSession(messageIds: [firstMessageId])
        defer { await connected.model.disconnect() }

        let response = try await connected.session.prompt([textBlock("go")])
        #expect(response.messageId == firstMessageId)
        let local = try #require(connected.userMessages.first)
        #expect(local.messageId == firstMessageId)
        #expect(local.sendState == .sent)

        try await connected.agent.send([
            echo(firstMessageId, text: "go"),
            running,
            agentChunk(text: "hello"),
            idleState(stopReason: .endTurn),
        ])
        try await waitForObservation {
            connected.session.agentState == .idle(IdleStateUpdate(stopReason: .endTurn))
        } orFailWhen: {
            connected.session.isClosed
        }

        #expect(connected.userMessages.count == 1)
        #expect(connected.userMessages.first === local)
        #expect(local.content == [textBlock("go")])
        #expect(connected.agentText == "hello")
    }

    /// G3 (1): after the prompt ended, the agent works with no prompt open: a
    /// compaction. `running`, the compaction entry and an `idle` with no stop
    /// reason reach the model.
    @Test func workWithNoPromptOpenReachesTheModelAndItsIdleHasNoStopReason() async throws {
        let connected = try await MailOrderSession(messageIds: [firstMessageId])
        defer { await connected.model.disconnect() }
        _ = try await connected.session.prompt([textBlock("go")])
        try await connected.agent.send([
            echo(firstMessageId, text: "go"),
            running,
            agentChunk(text: "hello"),
            idleState(stopReason: .endTurn),
        ])
        try await waitForObservation {
            connected.session.agentState == .idle(IdleStateUpdate(stopReason: .endTurn))
        } orFailWhen: {
            connected.session.isClosed
        }

        try await connected.agent.send([running, SessionModelFixtures.compactionUpdate(.inProgress)])
        try await waitForObservation { connected.session.transcript.last?.compaction != nil } orFailWhen: {
            connected.session.isClosed
        }
        #expect(connected.session.agentState == .running(RunningStateUpdate()))
        let compaction = try #require(connected.session.transcript.last?.compaction)
        #expect(compaction.status == .inProgress)
        #expect(compaction.timing.endedAt == nil)

        try await connected.agent.send([
            SessionModelFixtures.compactionUpdate(.completed),
            idleState(stopReason: nil),
        ])
        try await waitForObservation {
            connected.session.agentState == .idle(IdleStateUpdate(stopReason: nil))
        } orFailWhen: {
            connected.session.isClosed
        }

        #expect(compaction.status == .completed)
        #expect(compaction.timing.endedAt != nil)
        #expect(connected.session.transcript.last?.compaction === compaction)
        #expect(connected.userMessages.count == 1)
    }

    /// G3 (2): a second prompt while the first one is open gets its own
    /// answer. The two echoes come in the other order, and each local user
    /// message links to its own echo.
    @Test func twoOpenPromptsEachLinkToTheirOwnEchoInEitherOrder() async throws {
        let connected = try await MailOrderSession(messageIds: [firstMessageId, secondMessageId])
        defer { await connected.model.disconnect() }

        _ = try await connected.session.prompt([textBlock("first")])
        _ = try await connected.session.prompt([textBlock("second")])
        let locals = connected.userMessages
        #expect(locals.map(\.messageId) == [firstMessageId, secondMessageId])
        #expect(locals.map(\.sendState) == [.sent, .sent])

        try await connected.agent.send([
            echo(secondMessageId, text: "second"),
            echo(firstMessageId, text: "first"),
            running,
            idleState(stopReason: .endTurn),
        ])
        try await waitForObservation {
            connected.session.agentState == .idle(IdleStateUpdate(stopReason: .endTurn))
        } orFailWhen: {
            connected.session.isClosed
        }

        let linked = connected.userMessages
        #expect(linked.count == 2)
        #expect(linked.first === locals.first)
        #expect(linked.last === locals.last)
        #expect(linked.map(\.content) == [[textBlock("first")], [textBlock("second")]])
    }

    /// G3 (3): `session/cancel` while the agent works. The prompt answer is
    /// already there; the session stays `running` until the agent sends the
    /// `idle` with the `cancelled` stop reason, when its model work ends.
    @Test func theIdleOfACancelComesLaterThanTheCancelAndTheSessionRunsUntilThen() async throws {
        let connected = try await MailOrderSession(messageIds: [firstMessageId])
        defer { await connected.model.disconnect() }
        _ = try await connected.session.prompt([textBlock("go")])
        try await connected.agent.send([echo(firstMessageId, text: "go"), running, agentChunk(text: "part")])
        try await waitForObservation { connected.agentText == "part" } orFailWhen: { connected.session.isClosed }

        try await connected.session.cancel()
        // This read has no failure event: `cancels` is a stream of the stub,
        // and no close of the connection ends it. It hangs when the cancel
        // does not reach the agent. This is a known limit of rule T1.
        var cancels = connected.agent.cancels.makeAsyncIterator()
        let cancel = try #require(await cancels.next())
        #expect(cancel.sessionId == testSession)
        #expect(connected.session.agentState == .running(RunningStateUpdate()))

        try await connected.agent.send(idleState(stopReason: .cancelled))
        try await waitForObservation {
            connected.session.agentState == .idle(IdleStateUpdate(stopReason: .cancelled))
        } orFailWhen: {
            connected.session.isClosed
        }

        #expect(connected.userMessages.count == 1)
        #expect(connected.agentText == "part")
    }

    /// G4: an elicitation that the agent sends with no prompt open is
    /// pending in the session. When the agent ends its request with
    /// `$/cancel_request`, the session removes it.
    @Test func anElicitationThatTheAgentCancelsLeavesThePendingList() async throws {
        let connected = try await MailOrderSession(messageIds: [])
        defer { await connected.model.disconnect() }

        let call = connected.agent.startElicitation(
            ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope)))
        // The call ends when the client refuses the elicitation. Then the
        // request never becomes pending.
        let callEnd = TaskEnd(of: call)
        try await waitForObservation { !connected.session.pendingElicitations.isEmpty } orFailWhen: {
            callEnd.hasEnded || connected.session.isClosed
        }
        #expect(connected.session.pendingElicitations.map(\.request.message) == [ElicitationFixtures.formMessage])

        call.cancel()
        try await waitForObservation { connected.session.pendingElicitations.isEmpty } orFailWhen: {
            connected.session.isClosed
        }

        await #expect(throws: (any Error).self) { try await call.value }
    }
}
