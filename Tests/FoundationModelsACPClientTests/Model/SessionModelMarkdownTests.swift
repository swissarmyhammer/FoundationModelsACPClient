import ACPMarkdown
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of `SessionModel.markdown(options:)`. The model gives the
// renderer of `ACPMarkdown` the wire entries of its transcript, so the text
// of the model must be the text of the renderer for the same updates. A local
// entry that the agent did not get is not in the text.

/// The text of the prompt that the tests send.
private let promptText = "Please list the files."

/// The update stream of a short session: a title, a user message, a
/// thought, an agent message in two chunks, and a tool call.
private let scriptedUpdates: [SessionUpdate] = [
    .sessionInfoUpdate(SessionInfoUpdate(title: .value("Listing files"))),
    userChunk(text: promptText),
    thoughtChunk(text: "The user wants a list."),
    agentChunk(text: "Here are "),
    agentChunk(text: "the **files**:\n\n- a.swift\n"),
    toolCallStatus(id: "tool-1", .completed),
]

/// The update stream of a session where the agent sent one message.
private let agentReady = [agentChunk(text: "Ready.")]

/// The echo of the prompt that the agent inserts for the prompt of the tests.
private let promptEcho = userChunk(text: promptText, message: testPromptResponse.messageId.rawValue)

/// The tests of the Markdown document of a session model.
@MainActor
@Suite
struct SessionModelMarkdownTests {
    /// The fake sender of the model under test.
    let sender = FakeSessionRequestSender()

    /// Makes a model that folded the given updates live.
    ///
    /// - Parameter updates: The updates to fold, in order.
    /// - Returns: The model.
    func liveModel(_ updates: [SessionUpdate]) -> SessionModel {
        let model = SessionModelFixtures.makeModel(sender: sender)
        model.applyEach(updates)
        return model
    }

    @Test func theModelGivesTheTextOfTheRendererForTheSameUpdates() {
        let model = liveModel(scriptedUpdates)

        #expect(model.markdown() == SessionMarkdown.render(updates: scriptedUpdates))
    }

    @Test func theModelGivesTheOptionsToTheRenderer() {
        let options = SessionMarkdown.Options(includeThoughts: true, agentName: "Testudo")
        let model = liveModel(scriptedUpdates)

        #expect(model.markdown(options: options) == SessionMarkdown.render(updates: scriptedUpdates, options: options))
    }

    @Test func aPendingLocalUserMessageIsNotInTheDocument() async {
        let model = liveModel(agentReady)
        let call = await model.startPrompt(promptText, heldBy: sender)

        let documentWhilePending = model.markdown()

        sender.failPrompt(with: ConnectionError.closed)
        await #expect(throws: ConnectionError.closed) { try await call.value }
        #expect(documentWhilePending == SessionMarkdown.render(updates: agentReady))
    }

    @Test func aFailedLocalUserMessageIsNotInTheDocument() async {
        let model = liveModel(agentReady)
        let call = await model.startPrompt(promptText, heldBy: sender)
        sender.failPrompt(with: ConnectionError.closed)
        await #expect(throws: ConnectionError.closed) { try await call.value }

        #expect(model.markdown() == SessionMarkdown.render(updates: agentReady))
    }

    @Test func aLocalErrorEntryIsNotInTheDocument() {
        let model = liveModel(agentReady)

        model.appendError(code: .internalError, message: "The request failed.", data: nil)

        #expect(model.markdown() == SessionMarkdown.render(updates: agentReady))
    }

    @Test func aLinkedLocalUserMessageIsInTheDocument() async throws {
        let model = SessionModelFixtures.makeModel(sender: sender)
        let call = await model.startPrompt(promptText, heldBy: sender)
        sender.answerPrompt(with: testPromptResponse)
        _ = try await call.value

        model.apply(promptEcho)

        #expect(model.markdown() == SessionMarkdown.render(updates: [promptEcho]))
    }

    @Test func aReplayIntoANewModelGivesTheTextOfTheLiveModel() {
        let live = liveModel(scriptedUpdates)
        let replayed = SessionModelFixtures.makeModel(sender: FakeSessionRequestSender())

        replayed.beginReplay(replayFrom: SessionModelFixtures.replayFromStart)
        replayed.applyEach(scriptedUpdates)
        replayed.endReplay(succeeded: true)

        #expect(replayed.markdown() == live.markdown())
    }

    @Test func twoCallsOnTheSameModelGiveTheSameText() {
        let model = liveModel(scriptedUpdates)

        #expect(model.markdown() == model.markdown())
    }
}
