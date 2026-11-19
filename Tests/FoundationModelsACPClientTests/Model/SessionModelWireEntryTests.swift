import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the two reads for session search (D207):
// `SessionModel.entry(forWireID:)` and `SessionModel.wireEntries`. A search
// hit names its entry by the wire id, and the local index of the app reads
// the merged engine entries. A search hit gives the wire id in the text form
// of FoundationModelsACP (`SessionEntry.ID.searchHitID`), and
// `SessionEntry.ID(searchHitID:)` reads it back. This package keeps no copy
// of that form.

/// The id of the user message of the scripted session.
private let userMessageID = FoundationModelsACP.SessionEntry.ID.userMessage(MessageId(rawValue: "user-1"))

/// The id of the agent message of the scripted session.
private let agentMessageID = FoundationModelsACP.SessionEntry.ID.agentMessage(MessageId(rawValue: "agent-1"))

/// The id of the tool call of the scripted session.
private let toolCallID = FoundationModelsACP.SessionEntry.ID.toolCall(ToolCallId(rawValue: "tool-1"))

/// The id of an entry that no update of the scripted session gives.
private let unknownMessageID = FoundationModelsACP.SessionEntry.ID.agentMessage(MessageId(rawValue: "agent-unknown"))

/// The update stream of a session with a user message, an agent message and
/// a tool call.
private let scriptedUpdates: [SessionUpdate] = [
    userChunk(text: "Please list the files."),
    agentChunk(text: "Here are the files."),
    toolCallStatus(id: "tool-1", .completed),
]

/// The agent message that only a replay gives, and that a failed replay
/// removes again.
private let replayOnlyMessage = agentChunk(text: "Only in the replay.", message: "agent-replay")

/// The id of the agent message that only a replay gives.
private let replayOnlyMessageID = FoundationModelsACP.SessionEntry.ID.agentMessage(MessageId(rawValue: "agent-replay"))

/// The id of the agent thought of the session with each kind of entry.
private let thoughtID = FoundationModelsACP.SessionEntry.ID.agentThought(MessageId(rawValue: "thought-1"))

/// The terminal id of the session with each kind of entry.
private let terminalWireID = TerminalId(rawValue: "terminal-1")

/// The plan id of the session with each kind of entry.
private let planWireID = PlanId(rawValue: "plan-1")

/// The message id of the inter-session message of the session with each kind
/// of entry.
private let sessionMessageWireID = MessageId(rawValue: "session-message-1")

/// The update stream of a session with one entry of each case of
/// `SessionEntry.ID`. The last update has no wire id, so the engine gives
/// its entry the case `unidentified(position:)`.
private let everyKindUpdates: [SessionUpdate] = scriptedUpdates + [
    thoughtChunk(text: "Read the folder first."),
    .terminalUpdate(TerminalUpdate(terminalId: terminalWireID, command: .value("ls"))),
    .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: [], planId: planWireID)))),
    SessionModelFixtures.compactionUpdate(.completed),
    .sessionMessage(SessionMessage(messageId: sessionMessageWireID, content: .value([textBlock("Hello.")]))),
    .unknown("future_update", .object([:])),
]

/// The wire id of each entry of the session with each kind of entry, one for
/// each case of `SessionEntry.ID`. Each update adds one entry, and the
/// unidentified entry is the last entry. Thus its position is the count of
/// the updates before it.
private let everyKindIDs: [FoundationModelsACP.SessionEntry.ID] = [
    userMessageID,
    agentMessageID,
    toolCallID,
    thoughtID,
    .terminal(terminalWireID),
    .plan(planWireID),
    .compaction(SessionModelFixtures.compactionId),
    .sessionMessage(sessionMessageWireID),
    .unidentified(position: everyKindUpdates.count - 1),
]

/// The tests of the wire-id reads of a session model.
@MainActor
@Suite
struct SessionModelWireEntryTests {
    /// The fake sender of the model under test.
    let sender = FakeSessionRequestSender()

    /// Makes a model that folded the given updates live.
    ///
    /// - Parameter updates: The updates to fold, in order.
    /// - Returns: The model.
    func liveModel(of updates: [SessionUpdate] = scriptedUpdates) -> SessionModel {
        let model = SessionModelFixtures.makeModel(sender: sender)
        model.applyEach(updates)
        return model
    }

    @Test func eachWireIDGivesItsTranscriptEntry() {
        let model = liveModel()

        let found = [userMessageID, agentMessageID, toolCallID].map { model.entry(forWireID: $0)?.id }

        #expect(found == model.transcript.map(\.id))
    }

    @Test func anUnknownWireIDGivesNil() {
        let model = liveModel()

        #expect(model.entry(forWireID: unknownMessageID) == nil)
    }

    @Test func theIDOfAnEntryThatARollbackRemovedGivesNil() {
        let model = liveModel()

        model.replay(scriptedUpdates + [replayOnlyMessage], succeeded: false)

        #expect(model.entry(forWireID: replayOnlyMessageID) == nil)
    }

    @Test(arguments: everyKindIDs)
    func theTextFormOfAWireIDReadsBackTheSameID(_ id: FoundationModelsACP.SessionEntry.ID) {
        #expect(FoundationModelsACP.SessionEntry.ID(searchHitID: id.searchHitID) == id)
    }

    @Test(arguments: everyKindIDs)
    func theParsedTextFormOfAWireIDGivesTheEntryOfThatID(_ id: FoundationModelsACP.SessionEntry.ID) throws {
        let model = liveModel(of: everyKindUpdates)
        let expected = try #require(model.entry(forWireID: id))

        let parsed = try #require(FoundationModelsACP.SessionEntry.ID(searchHitID: id.searchHitID))

        #expect(model.entry(forWireID: parsed)?.id == expected.id)
    }

    @Test func wireEntriesGiveTheEngineEntriesInOrder() {
        let model = liveModel()

        #expect(model.wireEntries == SessionMergeEngine(replaying: scriptedUpdates).entries)
    }

    @Test func wireEntriesKeepTheEngineOrderWhenAnEchoArrivesAfterAnAgentMessage() async throws {
        let model = try await SessionModelFixtures.echoAfterAgentMessageModel()

        let expected = SessionMergeEngine(replaying: SessionModelFixtures.echoAfterAgentMessageUpdates).entries
        #expect(model.wireEntries == expected)
    }

    @Test func wireEntriesOfAReplayAreTheWireEntriesOfTheLiveModel() {
        let models = SessionModelFixtures.liveAndReplayedModels(of: scriptedUpdates)

        #expect(models.replayed.wireEntries == models.live.wireEntries)
    }
}
