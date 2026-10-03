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
        userChunk(text: "ask", message: "user-1"),
        .userMessage(UserMessage(messageId: userID, content: .value([textBlock("question")]))),
        agentChunk(text: "draft", message: "agent-1"),
        .agentMessage(AgentMessage(messageId: agentID, content: .value([textBlock("answer")]))),
        thoughtChunk(text: "hmm", message: "thought-1"),
        .agentThought(AgentThought(messageId: thoughtID, content: .value([textBlock("reasoning")]))),
        .stateUpdate(.running(RunningStateUpdate())),
        .toolCallUpdate(
            ToolCallUpdate(toolCallId: callID, status: .value(.pending), title: .value("Search"))
        ),
        .toolCallContentChunk(
            ToolCallContentChunk(content: .content(Content(content: textBlock("line"))), toolCallId: callID)
        ),
        toolCallStatus(id: "call-1", .completed),
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
        ScriptedStubAgent(connection: agentSide, session: testSession, script: fullScript())
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

/// The decode tests for the wire fields that ACP schema v2.0.0-alpha.7 added
/// and that this client reads: the message id of a prompt response, the
/// tool-call name patch, and the initial command list of a new or resumed
/// session.
///
/// Each test decodes the JSON text an agent writes, so a schema change that
/// renames, drops, or loosens one of these fields fails here first.
struct AlphaSevenWireDecodeTests {
    /// The raw message id that the prompt-response JSON carries.
    private static let promptedMessageID = "user-message-1"

    /// The tool-call name that the tool-call JSON carries.
    private static let toolName = "read_file"

    /// The `availableCommands` member that holds the scripted command, as an
    /// agent writes it.
    private static let scriptedCommandsMember =
        #""availableCommands":[{"description":"Makes a plan","name":"create_plan"}]"#

    /// Decodes one wire value from the JSON text an agent writes.
    ///
    /// - Parameters:
    ///   - type: The wire type to decode.
    ///   - json: The JSON text.
    /// - Returns: The decoded value.
    /// - Throws: The `DecodingError` of the decoder.
    private static func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func promptResponseDecodesTheMessageIdOfTheInsertedUserMessage() throws {
        let response = try Self.decode(
            PromptResponse.self,
            from: #"{"messageId":"\#(Self.promptedMessageID)"}"#
        )

        #expect(response.messageId == MessageId(rawValue: Self.promptedMessageID))
    }

    @Test(arguments: [#"{}"#, #"{"messageId":null}"#])
    func promptResponseWithoutAMessageIdDoesNotDecode(json: String) {
        #expect(throws: DecodingError.self) {
            try Self.decode(PromptResponse.self, from: json)
        }
    }

    @Test(arguments: [
        (#""#, PatchField<String>.unchanged),
        (#","name":null"#, PatchField<String>.cleared),
        (#","name":"\#(toolName)""#, PatchField<String>.value(toolName)),
    ])
    func toolCallUpdateDecodesTheNameAsAPatch(nameMember: String, expected: PatchField<String>) throws {
        let update = try Self.decode(
            ToolCallUpdate.self,
            from: #"{"toolCallId":"call-1"\#(nameMember)}"#
        )

        #expect(update.name == expected)
    }

    @Test func newSessionResponseWithoutCommandsDecodesNoCommandList() throws {
        let response = try Self.decode(
            NewSessionResponse.self,
            from: #"{"sessionId":"\#(testSession.rawValue)"}"#
        )

        #expect(response.availableCommands == nil)
    }

    @Test func newSessionResponseDecodesTheInitialCommands() throws {
        let response = try Self.decode(
            NewSessionResponse.self,
            from: #"{"sessionId":"\#(testSession.rawValue)",\#(Self.scriptedCommandsMember)}"#
        )

        #expect(response.availableCommands == [scriptedCommand])
    }

    @Test func resumeSessionResponseWithoutCommandsDecodesNoCommandList() throws {
        let response = try Self.decode(ResumeSessionResponse.self, from: #"{}"#)

        #expect(response.availableCommands == nil)
    }

    @Test func resumeSessionResponseDecodesTheInitialCommands() throws {
        let response = try Self.decode(
            ResumeSessionResponse.self,
            from: #"{\#(Self.scriptedCommandsMember)}"#
        )

        #expect(response.availableCommands == [scriptedCommand])
    }
}
