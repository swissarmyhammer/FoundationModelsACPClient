import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the two reads for session search (D207):
// `SessionModel.entry(forWireID:)` and `SessionModel.wireEntries`. A search
// hit names its entry by the wire id, and the local index of the app reads
// the merged engine entries.

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

/// The text of the prompt that the tests send.
private let promptText = "Please list the files."

/// The agent message that arrives while the prompt waits for its response.
private let earlyAgentMessage = agentChunk(text: "Ready.")

/// The echo of the prompt that the agent inserts for the prompt of the tests.
private let promptEcho = userChunk(text: promptText, message: testPromptResponse.messageId.rawValue)

/// The tests of the wire-id reads of a session model.
@MainActor
@Suite
struct SessionModelWireEntryTests {
    /// The fake sender of the model under test.
    let sender = FakeSessionRequestSender()

    /// Makes a model that folded the scripted updates live.
    ///
    /// - Returns: The model.
    func liveModel() -> SessionModel {
        let model = SessionModelFixtures.makeModel(sender: sender)
        model.applyEach(scriptedUpdates)
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
        model.beginReplay(replayFrom: SessionModelFixtures.replayFromStart)
        model.applyEach(scriptedUpdates + [replayOnlyMessage])

        model.endReplay(succeeded: false)

        #expect(model.entry(forWireID: replayOnlyMessageID) == nil)
    }

    @Test func wireEntriesGiveTheEngineEntriesInOrder() {
        let model = liveModel()

        #expect(model.wireEntries == SessionMergeEngine(replaying: scriptedUpdates).entries)
    }

    @Test func wireEntriesKeepTheEngineOrderWhenAnEchoArrivesAfterAnAgentMessage() async throws {
        let model = SessionModelFixtures.makeModel(sender: sender)
        let call = await model.startPrompt(promptText, heldBy: sender)
        model.applyEach([earlyAgentMessage, promptEcho])
        sender.answerPrompt(with: testPromptResponse)
        _ = try await call.value

        #expect(model.wireEntries == SessionMergeEngine(replaying: [earlyAgentMessage, promptEcho]).entries)
    }

    @Test func wireEntriesOfAReplayAreTheWireEntriesOfTheLiveModel() {
        let live = liveModel()
        let replayed = SessionModelFixtures.makeModel(sender: FakeSessionRequestSender())

        replayed.beginReplay(replayFrom: SessionModelFixtures.replayFromStart)
        replayed.applyEach(scriptedUpdates)
        replayed.endReplay(succeeded: true)

        #expect(replayed.wireEntries == live.wireEntries)
    }
}
