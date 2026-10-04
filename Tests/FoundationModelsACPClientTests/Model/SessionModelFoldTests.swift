import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the fold of `SessionModel`: each `SessionUpdate` case goes
// through the FoundationModelsACP merge engine, and lands in one transcript
// entry object or in one last-value property. The engine owns the merge
// rules, so these tests check that the model reflects each rule.

/// The raw stop reason that this schema revision does not know.
private let truncatedStopReason = "_truncated"

/// The command that the command tests advertise.
private let planCommand = AvailableCommand(description: "Makes a plan", name: "create_plan")

/// The configuration option that the option tests report.
private let modeOption = SessionConfigOption(
    configId: SessionConfigId(rawValue: "mode"),
    name: "Mode",
    type: .boolean(SessionConfigBoolean(currentValue: true))
)

/// The plan id that the plan tests use.
private let planId = PlanId(rawValue: "plan-1")

/// The terminal id that the terminal tests use.
private let terminalId = TerminalId(rawValue: "terminal-1")

/// The id of a second terminal, for the tests that need two terminals.
private let otherTerminalId = TerminalId(rawValue: "terminal-2")

/// Terminal output that is not valid base64, so the engine cannot decode it.
private let notBase64 = "!!! not base64 !!!"

/// The tool-call id that the tool-call tests use.
private let toolCallId = ToolCallId(rawValue: "tool-1")

/// The id of a second tool call, for the tests that need two tool calls.
private let otherToolCallId = ToolCallId(rawValue: "tool-2")

/// Each tool-call status of the schema. A queued call (`pending`) and a
/// running call (`inProgress`) must stay two states.
private let everyToolCallStatus: [ToolCallStatus] = [.pending, .inProgress, .completed, .failed, .cancelled]

/// Makes a model for the test session, and folds each update into it.
///
/// The model has no coalescing cadence, so each chunk that a test applies to
/// it later also folds at once.
///
/// - Parameter updates: The updates to fold, in order.
/// - Returns: The model.
@MainActor
private func foldedModel(_ updates: SessionUpdate...) -> SessionModel {
    let model = SessionModelFixtures.immediateModel()
    for update in updates {
        model.apply(update)
    }
    return model
}

/// Makes a plan update with one item.
///
/// - Parameter content: The text of the item.
/// - Returns: The update.
private func planUpdate(_ content: String) -> SessionUpdate {
    .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: [planItem(content)], planId: planId))))
}

/// Makes a plan item with a fixed priority and status.
///
/// - Parameter content: The text of the item.
/// - Returns: The item.
private func planItem(_ content: String) -> PlanEntry {
    PlanEntry(content: content, priority: .medium, status: .pending)
}

/// Makes a terminal-output-chunk update.
///
/// - Parameters:
///   - text: The text of the chunk, which the update carries in base64.
///   - terminal: The terminal that gets the bytes.
/// - Returns: The update.
private func terminalChunk(_ text: String, for terminal: TerminalId = terminalId) -> SessionUpdate {
    .terminalOutputChunk(TerminalOutputChunk(data: Data(text.utf8).base64EncodedString(), terminalId: terminal))
}

extension ToolCallContent {
    /// The id of the terminal that this content refers to, or `nil` for
    /// content that is not a terminal reference.
    fileprivate var referencedTerminalId: TerminalId? {
        if case .terminal(let reference) = self { reference.terminalId } else { nil }
    }
}

/// The fold tests, in one suite so that `swift test --filter
/// SessionModelFoldTests` selects them.
@MainActor
struct SessionModelFoldTests {
    // MARK: - Identity and the empty state

    @Test func newModelHasTheSessionIdAndNoState() {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())

        #expect(model.sessionId == testSession)
        #expect(model.transcript.isEmpty)
        #expect(model.availableCommands == nil)
        #expect(model.configOptions == nil)
        #expect(model.usage == nil)
        #expect(model.agentState == nil)
        #expect(model.sessionInfo == SessionInfoUpdate())
    }

    // MARK: - Messages

    @Test func userMessageChunkAddsAUserMessageEntry() throws {
        let model = foldedModel(userChunk(text: "Hello"))

        let entry = try #require(model.transcript.first?.userMessage)
        #expect(model.transcript.map(\.id) == [.wire(.userMessage(MessageId(rawValue: "user-1")))])
        #expect(entry.content == [textBlock("Hello")])
        #expect(entry.sendState == .sent)
    }

    @Test func userMessageReplacesTheContentOfTheSameObject() throws {
        let model = foldedModel(userChunk(text: "Hel"))
        let entry = try #require(model.transcript.first?.userMessage)

        let whole = UserMessage(messageId: MessageId(rawValue: "user-1"), content: .value([textBlock("Hello there")]))
        model.apply(.userMessage(whole))

        #expect(model.transcript.map(\.id) == [entry.id])
        #expect(model.transcript.first?.userMessage === entry)
        #expect(entry.content == [textBlock("Hello there")])
    }

    @Test func agentMessageChunksAppendToTheSameObject() throws {
        let model = foldedModel(agentChunk(text: "Hel"))
        let entry = try #require(model.transcript.first?.agentMessage)

        model.apply(agentChunk(text: "lo"))

        #expect(model.transcript.map(\.id) == [.wire(.agentMessage(MessageId(rawValue: "agent-1")))])
        #expect(model.transcript.first?.agentMessage === entry)
        #expect(entry.content == [textBlock("Hel"), textBlock("lo")])
    }

    @Test func agentMessageReplacesTheContentOfTheSameObject() throws {
        let model = foldedModel(agentChunk(text: "Hel"))
        let entry = try #require(model.transcript.first?.agentMessage)

        let whole = AgentMessage(messageId: MessageId(rawValue: "agent-1"), content: .value([textBlock("Final")]))
        model.apply(.agentMessage(whole))

        #expect(model.transcript.first?.agentMessage === entry)
        #expect(entry.content == [textBlock("Final")])
    }

    @Test func agentThoughtChunkAddsAThoughtBesideTheMessageWithTheSameId() throws {
        let model = foldedModel(agentChunk(text: "Answer", message: "turn-1"), thoughtChunk(text: "Reason", message: "turn-1"))

        let turnId = MessageId(rawValue: "turn-1")
        #expect(model.transcript.map(\.id) == [.wire(.agentMessage(turnId)), .wire(.agentThought(turnId))])
        #expect(try #require(model.transcript.last?.thought).content == [textBlock("Reason")])
    }

    @Test func agentThoughtReplacesTheContentOfTheSameObject() throws {
        let model = foldedModel(thoughtChunk(text: "Think"))
        let entry = try #require(model.transcript.first?.thought)

        let whole = AgentThought(messageId: MessageId(rawValue: "thought-1"), content: .value([textBlock("Thinking")]))
        model.apply(.agentThought(whole))

        #expect(model.transcript.first?.thought === entry)
        #expect(entry.content == [textBlock("Thinking")])
    }

    @Test func wholeUserMessageAndThoughtUpsertsAddTheirEntries() throws {
        let userId = MessageId(rawValue: "user-9")
        let thoughtId = MessageId(rawValue: "thought-9")

        let model = foldedModel(
            .userMessage(UserMessage(messageId: userId, content: .value([textBlock("Question")]))),
            .agentThought(AgentThought(messageId: thoughtId, content: .value([textBlock("Reasoning")])))
        )

        #expect(model.transcript.map(\.id) == [.wire(.userMessage(userId)), .wire(.agentThought(thoughtId))])
        #expect(try #require(model.transcript.first?.userMessage).content == [textBlock("Question")])
        #expect(try #require(model.transcript.last?.thought).content == [textBlock("Reasoning")])
    }

    @Test func unknownContentBlockStaysRawInItsMessage() throws {
        let block = ContentBlock.unknown("future_block", .object(["detail": .string("x")]))
        let chunk = ContentChunk(content: block, messageId: MessageId(rawValue: "agent-1"))

        let model = foldedModel(.agentMessageChunk(chunk))

        #expect(try #require(model.transcript.first?.agentMessage).content == [block])
    }

    // MARK: - Tool calls

    @Test func toolCallUpdatesFoldIntoTheSameObject() throws {
        let model = foldedModel(toolCallStatus(id: "tool-1", .pending))
        let entry = try #require(model.transcript.first?.toolCall)

        model.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: toolCallId, name: .value("read_file"), status: .value(.completed))))

        #expect(model.transcript.map(\.id) == [.wire(.toolCall(toolCallId))])
        #expect(model.transcript.first?.toolCall === entry)
        #expect(entry.status == .completed)
        #expect(entry.name == "read_file")
    }

    @Test func toolCallContentChunkAppendsContentToTheSameObject() throws {
        let model = foldedModel(toolCallStatus(id: "tool-1", .inProgress))
        let entry = try #require(model.transcript.first?.toolCall)
        let firstLine = ToolCallContent.content(Content(content: textBlock("line-1")))
        let secondLine = ToolCallContent.content(Content(content: textBlock("line-2")))

        model.apply(.toolCallContentChunk(ToolCallContentChunk(content: firstLine, toolCallId: toolCallId)))
        model.apply(.toolCallContentChunk(ToolCallContentChunk(content: secondLine, toolCallId: toolCallId)))

        #expect(model.transcript.first?.toolCall === entry)
        #expect(entry.content == [firstLine, secondLine])
    }

    @Test func toolCallContentChunkForAnUnseenIdAddsTheToolCall() throws {
        let line = ToolCallContent.content(Content(content: textBlock("line-1")))

        let model = foldedModel(.toolCallContentChunk(ToolCallContentChunk(content: line, toolCallId: toolCallId)))

        #expect(model.transcript.map(\.id) == [.wire(.toolCall(toolCallId))])
        #expect(try #require(model.transcript.first?.toolCall).content == [line])
    }

    @Test func twoToolCallsWithTheSameNameStayTwoEntries() throws {
        let model = foldedModel(
            .toolCallUpdate(ToolCallUpdate(toolCallId: toolCallId, name: .value("shell"), status: .value(.inProgress))),
            .toolCallUpdate(ToolCallUpdate(toolCallId: otherToolCallId, name: .value("shell"), status: .value(.inProgress))),
            toolCallStatus(id: toolCallId.rawValue, .completed)
        )

        #expect(model.transcript.map(\.id) == [.wire(.toolCall(toolCallId)), .wire(.toolCall(otherToolCallId))])
        #expect(try #require(model.transcript.first?.toolCall).status == .completed)
        #expect(try #require(model.transcript.last?.toolCall).status == .inProgress)
    }

    @Test(arguments: everyToolCallStatus)
    func eachToolCallStatusLandsDistinctly(status: ToolCallStatus) throws {
        let model = foldedModel(toolCallStatus(id: toolCallId.rawValue, status))

        #expect(try #require(model.transcript.first?.toolCall).status == status)
    }

    // MARK: - Terminals

    @Test func terminalUpdateAddsATerminalEntry() throws {
        let model = foldedModel(.terminalUpdate(TerminalUpdate(terminalId: terminalId, command: .value("ls"))))

        #expect(model.transcript.map(\.id) == [.wire(.terminal(terminalId))])
        #expect(try #require(model.transcript.first?.terminal).command == "ls")
    }

    @Test func terminalChunkAppendsBytes() throws {
        let model = foldedModel(terminalChunk("ab"))
        let entry = try #require(model.transcript.first?.terminal)

        model.apply(terminalChunk("cd"))

        #expect(model.transcript.first?.terminal === entry)
        #expect(entry.bytes == Data("abcd".utf8))
    }

    @Test func terminalOutputSnapshotReplacesBytes() throws {
        let model = foldedModel(terminalChunk("old output"))
        let entry = try #require(model.transcript.first?.terminal)

        let snapshot = TerminalOutput(data: Data("new".utf8).base64EncodedString())
        model.apply(.terminalUpdate(TerminalUpdate(terminalId: terminalId, output: .value(snapshot))))

        #expect(model.transcript.first?.terminal === entry)
        #expect(entry.bytes == Data("new".utf8))
    }

    @Test func interleavedTerminalChunksAccumulateForEachTerminal() throws {
        let model = foldedModel(
            terminalChunk("one "),
            terminalChunk("alpha ", for: otherTerminalId),
            terminalChunk("two"),
            terminalChunk("beta", for: otherTerminalId)
        )

        #expect(model.transcript.map(\.id) == [.wire(.terminal(terminalId)), .wire(.terminal(otherTerminalId))])
        #expect(try #require(model.transcript.first?.terminal).bytes == Data("one two".utf8))
        #expect(try #require(model.transcript.last?.terminal).bytes == Data("alpha beta".utf8))
    }

    @Test func aTerminalChunkThatIsNotBase64ChangesNoBytes() throws {
        let model = foldedModel(terminalChunk("good "))
        let entry = try #require(model.transcript.first?.terminal)

        model.apply(.terminalOutputChunk(TerminalOutputChunk(data: notBase64, terminalId: terminalId)))
        model.apply(terminalChunk("still good"))

        #expect(entry.bytes == Data("good still good".utf8))
    }

    @Test func aTerminalSnapshotThatIsNotBase64KeepsTheBytes() throws {
        let model = foldedModel(terminalChunk("kept"))
        let entry = try #require(model.transcript.first?.terminal)

        model.apply(.terminalUpdate(TerminalUpdate(terminalId: terminalId, output: .value(TerminalOutput(data: notBase64)))))

        #expect(entry.bytes == Data("kept".utf8))
    }

    @Test func aTerminalReferenceOfAToolCallNamesTheIdOfItsTerminalEntry() throws {
        let reference = ToolCallContent.terminal(Terminal(terminalId: terminalId))
        let model = foldedModel(
            .terminalUpdate(TerminalUpdate(terminalId: terminalId, command: .value("ls"))),
            .toolCallContentChunk(ToolCallContentChunk(content: reference, toolCallId: toolCallId))
        )
        let toolCall = try #require(model.transcript.last?.toolCall)

        let referencedId = try #require(toolCall.content.first?.referencedTerminalId)

        let terminal = try #require(model.transcript.first { $0.id == .wire(.terminal(referencedId)) }?.terminal)
        #expect(terminal.command == "ls")
    }

    @Test func aTerminalReferenceToAnUnseenTerminalNamesNoEntry() {
        let reference = ToolCallContent.terminal(Terminal(terminalId: otherTerminalId))

        let model = foldedModel(.toolCallContentChunk(ToolCallContentChunk(content: reference, toolCallId: toolCallId)))

        #expect(!model.transcript.contains { $0.id == .wire(.terminal(otherTerminalId)) })
    }

    // MARK: - Plans

    @Test func planUpdateAddsAPlanEntry() throws {
        let model = foldedModel(planUpdate("Read the notes"))

        #expect(model.transcript.map(\.id) == [.wire(.plan(planId))])
        #expect(try #require(model.transcript.first?.plan).entries == [planItem("Read the notes")])
    }

    @Test func planReplaceKeepsPosition() throws {
        let model = foldedModel(planUpdate("Read the notes"), agentChunk(text: "Working"))
        let plan = try #require(model.transcript.first?.plan)

        model.apply(planUpdate("Write the answer"))

        #expect(model.transcript.map(\.id) == [.wire(.plan(planId)), .wire(.agentMessage(MessageId(rawValue: "agent-1")))])
        #expect(model.transcript.first?.plan === plan)
        #expect(plan.entries == [planItem("Write the answer")])
    }

    // MARK: - Unknown updates

    @Test func unknownUpdateBecomesUnknownEntry() throws {
        let payload: JSONValue = .object(["detail": .string("x")])

        let model = foldedModel(.unknown("future_update", payload))

        let entry = try #require(model.transcript.first?.unknown)
        #expect(model.transcript.map(\.id) == [.wire(.unidentified(position: 0))])
        #expect(entry.type == "future_update")
        #expect(entry.raw == payload)
    }

    @Test func anUnknownUpdateChangesNoOtherEntryAndNoAgentState() throws {
        let model = foldedModel(agentChunk(text: "Hello"), idleState(stopReason: .endTurn))
        let message = try #require(model.transcript.first?.agentMessage)

        model.apply(.unknown("future_update", .object([:])))

        #expect(model.transcript.first?.agentMessage === message)
        #expect(message.content == [textBlock("Hello")])
        #expect(model.agentState == .idle(IdleStateUpdate(stopReason: .endTurn)))
    }

    // MARK: - Last-value state

    @Test func runningStateUpdateSetsTheAgentState() {
        let model = foldedModel(.stateUpdate(.running(RunningStateUpdate())))

        #expect(model.agentState == .running(RunningStateUpdate()))
        #expect(model.transcript.isEmpty)
    }

    @Test func requiresActionStateUpdateReplacesTheAgentState() {
        let model = foldedModel(
            .stateUpdate(.running(RunningStateUpdate())),
            .stateUpdate(.requiresAction(RequiresActionStateUpdate()))
        )

        #expect(model.agentState == .requiresAction(RequiresActionStateUpdate()))
    }

    @Test func idleStateUpdateKeepsTheStopReason() {
        let model = foldedModel(idleState(stopReason: .endTurn))

        #expect(model.agentState == .idle(IdleStateUpdate(stopReason: .endTurn)))
    }

    @Test func truncatedStopReasonStaysRaw() {
        let model = foldedModel(idleState(stopReason: .unknown(truncatedStopReason)))

        #expect(model.agentState == .idle(IdleStateUpdate(stopReason: .unknown(truncatedStopReason))))
    }

    @Test func availableCommandsUpdateSetsTheCommands() {
        let model = foldedModel(.availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [planCommand])))

        #expect(model.availableCommands == [planCommand])
    }

    @Test func emptyAvailableCommandsUpdateGivesAnEmptyListNotNil() {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        #expect(model.availableCommands == nil)

        model.apply(.availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [])))

        #expect(model.availableCommands == [])
    }

    @Test func configOptionUpdateSetsTheOptions() {
        let model = foldedModel(.configOptionUpdate(ConfigOptionUpdate(configOptions: [modeOption])))

        #expect(model.configOptions == [modeOption])
    }

    @Test func usageUpdateSetsTheUsage() {
        let model = foldedModel(.usageUpdate(SessionModelFixtures.usage))

        #expect(model.usage == SessionModelFixtures.usage)
    }

    @Test func sessionInfoUpdateFoldsAsAPatch() {
        let model = foldedModel(
            .sessionInfoUpdate(SessionInfoUpdate(title: .value("Refactor"), updatedAt: .value("2026-10-03T00:00:00Z"))),
            .sessionInfoUpdate(SessionInfoUpdate(title: .cleared))
        )

        #expect(model.sessionInfo.title == .cleared)
        #expect(model.sessionInfo.updatedAt == .value("2026-10-03T00:00:00Z"))
    }

    // MARK: - Seed

    @Test func seedWithNilCommandsLeavesNil() {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())

        model.seed(availableCommands: nil, configOptions: [modeOption])

        #expect(model.availableCommands == nil)
        #expect(model.configOptions == [modeOption])
    }

    @Test func seedWithCommandsSetsThem() {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())

        model.seed(availableCommands: [planCommand], configOptions: nil)

        #expect(model.availableCommands == [planCommand])
        #expect(model.configOptions == nil)
    }

    // MARK: - Observation

    @Test func chunkForOneEntryFiresNoObservationOnAnotherEntry() throws {
        let model = foldedModel(agentChunk(text: "A", message: "agent-a"), agentChunk(text: "B", message: "agent-b"))
        let entryB = try #require(model.transcript.last?.agentMessage)

        let fired = observationFires {
            _ = (entryB.content, entryB.messageId, entryB.meta)
        } during: {
            model.apply(agentChunk(text: "more", message: "agent-a"))
        }

        #expect(!fired)
    }

    @Test func chunkForAKnownEntryFiresNoObservationOnTheTranscriptList() {
        let model = foldedModel(agentChunk(text: "A"))

        let fired = observationFires {
            _ = model.transcript
        } during: {
            model.apply(agentChunk(text: "more"))
        }

        #expect(!fired)
    }

    @Test func chunkForOneEntryFiresTheObservationOfThatEntry() throws {
        let model = foldedModel(agentChunk(text: "A"))
        let entry = try #require(model.transcript.first?.agentMessage)

        let fired = observationFires {
            _ = entry.content
        } during: {
            model.apply(agentChunk(text: "more"))
        }

        #expect(fired)
    }
}
