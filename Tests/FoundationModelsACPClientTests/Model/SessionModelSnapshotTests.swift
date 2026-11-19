import ACPMarkdown
import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of `SessionModel.snapshot(options:)`. The model gives
// `SessionSnapshot.build(updates:options:)` the wire entries of its
// transcript, so the snapshot of the model must be the snapshot of the
// builder for the same updates. A local entry that the agent did not get is
// not in the snapshot.

/// The title of the session of ``snapshotUpdates``.
private let sessionTitle = "Listing files"

/// The text of the thought of ``snapshotUpdates``.
private let thoughtText = "The user wants a list."

/// The raw output of the tool call of ``snapshotUpdates``.
private let toolOutputText = "a.swift b.swift"

/// The update stream of a short session: a title, a user message, a
/// thought, an agent message, and a tool call with a raw output.
private let snapshotUpdates: [SessionUpdate] = [
    .sessionInfoUpdate(SessionInfoUpdate(title: .value(sessionTitle))),
    userChunk(text: SessionModelFixtures.promptText),
    thoughtChunk(text: thoughtText),
    agentChunk(text: "Here are the files."),
    .toolCallUpdate(
        ToolCallUpdate(
            toolCallId: ToolCallId(rawValue: "tool-1"),
            rawOutput: .value(.string(toolOutputText)),
            status: .value(.completed),
            title: .value("List the files")
        )
    ),
]

/// The update stream of a session where the agent sent one message.
private let agentReady = [SessionModelFixtures.agentReadyMessage]

/// The tests of the share snapshot of a session model.
@MainActor
@Suite
struct SessionModelSnapshotTests {
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

    /// Gives the coded form of a snapshot as text.
    ///
    /// - Parameter snapshot: The snapshot to encode.
    /// - Returns: The JSON text of the snapshot.
    /// - Throws: `EncodingError` when an update cannot be encoded.
    func codedText(of snapshot: SessionSnapshot) throws -> String {
        String(decoding: try snapshot.encoded(), as: UTF8.self)
    }

    @Test func theSnapshotOfTheModelIsTheSnapshotOfTheBuilderForTheSameUpdates() {
        let model = liveModel(snapshotUpdates)

        #expect(model.snapshot(options: .init()) == SessionSnapshot.build(updates: snapshotUpdates))
    }

    @Test func aLocalErrorEntryIsNotInTheSnapshot() {
        let model = liveModel(agentReady)

        model.appendError(code: .internalError, message: "The request failed.", data: nil)

        #expect(model.snapshot(options: .init()) == SessionSnapshot.build(updates: agentReady))
    }

    @Test func aFailedLocalUserMessageIsNotInTheSnapshot() async {
        let model = liveModel(agentReady)
        let call = await model.startPrompt(SessionModelFixtures.promptText, heldBy: sender)
        sender.failPrompt(with: ConnectionError.closed)
        await #expect(throws: ConnectionError.closed) { try await call.value }

        #expect(model.snapshot(options: .init()) == SessionSnapshot.build(updates: agentReady))
    }

    @Test func theTitleOfTheSnapshotIsTheTitleOfTheSessionInfo() {
        let model = liveModel(snapshotUpdates)

        #expect(model.snapshot(options: .init()).options.title == sessionTitle)
    }

    @Test func theTitleOfTheOptionsWinsOverTheTitleOfTheSessionInfo() {
        let model = liveModel(snapshotUpdates)

        #expect(model.snapshot(options: .init(title: "Shared")).options.title == "Shared")
    }

    @Test func withNoThoughtsTheThoughtIsNotInTheSnapshot() throws {
        let model = liveModel(snapshotUpdates)

        let snapshot = model.snapshot(options: .init(includeThoughts: false))

        #expect(try !codedText(of: snapshot).contains(thoughtText))
    }

    @Test func withNoToolOutputTheToolOutputIsNotInTheSnapshot() throws {
        let model = liveModel(snapshotUpdates)

        let snapshot = model.snapshot(options: .init(includeToolOutput: false))

        #expect(try !codedText(of: snapshot).contains(toolOutputText))
    }
}
