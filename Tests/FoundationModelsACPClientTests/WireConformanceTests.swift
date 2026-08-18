import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// This test drives the container over the real ACP wire. A stub agent runs
// behind `InMemoryTransport.pair()` and sends one update for every
// `SessionUpdate` case during one prompt turn. The connection read loop
// applies each notification in wire order before it delivers the prompt
// acknowledgement, so the assertions run against the final state.

/// The context-window size that the scripted usage update reports.
private let scriptedContextWindowSize = 200_000

/// The used-token count that the scripted usage update reports.
private let scriptedUsedTokens = 1_500

/// A stub agent that sends a fixed update script during one prompt turn.
private final class StubAgent: Agent {
    /// The connection back to the client.
    private let connection: AgentSideConnection

    /// The session that the script belongs to.
    private let session: SessionId

    /// The updates to send, in order, when a prompt arrives.
    private let script: [SessionUpdate]

    /// Creates the stub.
    ///
    /// - Parameters:
    ///   - connection: The connection back to the client.
    ///   - session: The session that the script belongs to.
    ///   - script: The updates to send during the prompt turn.
    init(connection: AgentSideConnection, session: SessionId, script: [SessionUpdate]) {
        self.connection = connection
        self.session = session
        self.script = script
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "stub-agent", version: "1.0.0"),
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
        throw RequestError.methodNotFound("session/resume")
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        throw RequestError.methodNotFound("session/close")
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        for update in script {
            try await connection.sessionUpdate(
                UpdateSessionNotification(sessionId: session, update: update)
            )
        }
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

/// The scripted plan entry.
private let scriptedPlanEntry = PlanEntry(content: "read the file", priority: .medium, status: .inProgress)

/// The scripted command.
private let scriptedCommand = AvailableCommand(description: "Makes a plan", name: "create_plan")

/// The scripted configuration option.
private let scriptedOption = SessionConfigOption(
    configId: SessionConfigId(rawValue: "mode"),
    name: "Mode",
    type: .boolean(SessionConfigBoolean(currentValue: true))
)

/// The scripted usage report.
private let scriptedUsage = UsageUpdate(size: scriptedContextWindowSize, used: scriptedUsedTokens)

/// Makes the update script. It holds at least one update for every
/// `SessionUpdate` case.
///
/// - Returns: The updates, in send order.
private func fullScript() -> [SessionUpdate] {
    let userID = MessageId(rawValue: "user-1")
    let agentID = MessageId(rawValue: "agent-1")
    let thoughtID = MessageId(rawValue: "thought-1")
    let callID = ToolCallId(rawValue: "call-1")
    let terminalID = TerminalId(rawValue: "term-1")
    return [
        userChunk("ask", message: "user-1"),
        .userMessage(UserMessage(messageId: userID, content: .value([textBlock("question")]))),
        agentChunk("draft", message: "agent-1"),
        .agentMessage(AgentMessage(messageId: agentID, content: .value([textBlock("answer")]))),
        thoughtChunk("hmm", message: "thought-1"),
        .agentThought(AgentThought(messageId: thoughtID, content: .value([textBlock("reasoning")]))),
        .stateUpdate(.running(RunningStateUpdate())),
        .toolCallUpdate(
            ToolCallUpdate(toolCallId: callID, status: .value(.pending), title: .value("Search"))
        ),
        .toolCallContentChunk(
            ToolCallContentChunk(content: .content(Content(content: textBlock("line"))), toolCallId: callID)
        ),
        toolCallStatus("call-1", .completed),
        .terminalUpdate(TerminalUpdate(terminalId: terminalID, command: .value("ls"))),
        .terminalOutputChunk(
            TerminalOutputChunk(data: Data("hi".utf8).base64EncodedString(), terminalId: terminalID)
        ),
        .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: [scriptedPlanEntry], planId: PlanId(rawValue: "plan-1"))))),
        .availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [scriptedCommand])),
        .configOptionUpdate(ConfigOptionUpdate(configOptions: [scriptedOption])),
        .sessionInfoUpdate(SessionInfoUpdate(title: .value("Session title"))),
        .usageUpdate(scriptedUsage),
        .unknown("future_update", .object(["detail": .string("x")])),
        idleState(stopReason: .endTurn),
    ]
}

@MainActor @Test(.timeLimit(.minutes(1)))
func everySessionUpdateCaseLandsInObservableStateOverTheWire() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let model = SwiftUIACPClient()
    let connection = await ClientSideConnection(stream: clientEnd) { _ in model }
    let agentConnection = await AgentSideConnection(stream: agentEnd) { agentSide in
        StubAgent(connection: agentSide, session: testSession, script: fullScript())
    }

    _ = try await connection.prompt(
        PromptRequest(prompt: [textBlock("go")], sessionId: testSession)
    )

    let state = model.session(for: testSession)

    // The ordered entry list holds one stable entry for each identity, and
    // the unknown update adds nothing.
    #expect(
        state.entries == [
            .userMessage(MessageId(rawValue: "user-1")),
            .agentMessage(MessageId(rawValue: "agent-1")),
            .agentThought(MessageId(rawValue: "thought-1")),
            .toolCall(ToolCallId(rawValue: "call-1")),
        ]
    )

    // The whole-message upserts replaced the chunk content.
    #expect(state.messageContent(for: MessageId(rawValue: "user-1")) == [textBlock("question")])
    #expect(state.messageContent(for: MessageId(rawValue: "agent-1")) == [textBlock("answer")])
    #expect(state.messageContent(for: MessageId(rawValue: "thought-1")) == [textBlock("reasoning")])

    // The tool call folded its three updates into one record.
    let call = state.toolCalls[ToolCallId(rawValue: "call-1")]
    #expect(call?.status == .value(.completed))
    #expect(call?.title == .value("Search"))
    #expect(call?.content == .value([.content(Content(content: textBlock("line")))]))

    // The terminal accumulated its output bytes.
    let terminal = state.terminals[TerminalId(rawValue: "term-1")]
    #expect(terminal?.command == .value("ls"))
    #expect(terminal?.output == Data("hi".utf8))

    // The plan, the commands, the config options, the session info, and the
    // usage all landed.
    #expect(state.plans[PlanId(rawValue: "plan-1")] == [scriptedPlanEntry])
    #expect(state.availableCommands == [scriptedCommand])
    #expect(state.configOptions == [scriptedOption])
    #expect(state.title == "Session title")
    #expect(state.usage == scriptedUsage)

    // The turn ended: the state update drove the turn state and the stop
    // reason.
    #expect(state.turnState == .idle)
    #expect(state.lastStopReason == .endTurn)

    await connection.close()
    withExtendedLifetime(agentConnection) {}
}
