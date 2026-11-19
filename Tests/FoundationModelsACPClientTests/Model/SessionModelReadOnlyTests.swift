import ACPMarkdown
import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the read-only model of a share snapshot (D208). The model
// applies the updates of the snapshot through the update path of a live
// model, and it has no connection. Each request to the agent throws
// `SessionModelError.readOnly` before it sends anything.

/// The title of the share of ``ReadOnlyFixtures``.
private let shareTitle = "Listing files"

/// The fixtures of the read-only tests.
private enum ReadOnlyFixtures {
    /// The updates of one turn: a user message and an agent message.
    ///
    /// - Parameter number: The number of the turn. It makes the message ids
    ///   and the texts different for each turn.
    /// - Returns: The updates of the turn.
    static func turn(_ number: Int) -> [SessionUpdate] {
        [
            userChunk(text: "Question \(number)", message: "user-\(number)"),
            agentChunk(text: "Answer \(number)", message: "agent-\(number)"),
        ]
    }

    /// The updates of the first turns of the session.
    static let firstTurns = turn(1) + [thoughtChunk(text: "The user wants a list.")] + turn(2)

    /// The updates of the first turns and two more turns.
    static let fourTurns = firstTurns + turn(3) + turn(4)

    /// The updates of a session whose last agent message is not complete.
    static let partialAnswer = [userChunk(text: "Question", message: "user-1"), agentChunk(text: "Hel", message: "agent-1")]

    /// The updates of ``partialAnswer``, with the rest of the agent message.
    static let completeAnswer = partialAnswer + [agentChunk(text: "lo", message: "agent-1")]

    /// Makes the snapshot of updates, with the share title.
    ///
    /// - Parameter updates: The updates of the session.
    /// - Returns: The snapshot.
    static func snapshot(of updates: [SessionUpdate]) -> SessionSnapshot {
        SessionSnapshot.build(updates: updates, options: .init(title: shareTitle))
    }

    /// The request that changes the mode of the session: a mode is a
    /// configuration option.
    static let setModeRequest = SetSessionConfigOptionRequest(
        configId: SessionConfigId(rawValue: "mode"),
        sessionId: testSession,
        value: .id(SessionConfigValueId(rawValue: "fast"))
    )

    /// Makes a read-only model of ``firstTurns`` that sends its requests
    /// through a sender of the test.
    ///
    /// - Parameter sender: The sender of the model.
    /// - Returns: The model.
    @MainActor
    static func readOnlyModel(sender: RecordingSessionRequestSender) -> SessionModel {
        SessionModel(snapshot: snapshot(of: firstTurns), sessionId: testSession, requestSender: sender)
    }
}

/// A request sender that records the ACP method of each request that
/// reaches it, and fails each request at once.
///
/// It never suspends, so a test of a model that sends a request in error
/// ends with a failure and does not wait.
final class RecordingSessionRequestSender: SessionRequestSender {
    /// The ACP method of each request that reached the sender, in order.
    let sentMethods = ThreadSafeBuffer<String>()

    /// Records the prompt, and fails it.
    ///
    /// - Parameters:
    ///   - request: The prompt request.
    ///   - willSend: Not called.
    /// - Returns: Never returns.
    /// - Throws: `ConnectionError.closed` always.
    func prompt(
        _ request: PromptRequest,
        willSend: @MainActor @Sendable (PromptRequest) -> Void
    ) async throws -> PromptResponse {
        sentMethods.append(ClientRequestSpan.Method.prompt)
        throw ConnectionError.closed
    }

    /// Records the cancel, and fails it.
    ///
    /// - Parameters:
    ///   - notification: The cancel notification.
    ///   - link: The link of the cancel span; not used.
    /// - Throws: `ConnectionError.closed` always.
    func cancel(_ notification: CancelSessionNotification, linkingTo link: JSONValue?) async throws {
        sentMethods.append(ClientRequestSpan.Method.cancelSession)
        throw ConnectionError.closed
    }

    /// Records the set-config-option request, and fails it.
    ///
    /// - Parameter request: The set-config-option request.
    /// - Throws: `ConnectionError.closed` always.
    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {
        sentMethods.append(ClientRequestSpan.Method.setConfigOption)
        throw ConnectionError.closed
    }
}

/// One row of a transcript that a test compares: the wire id and the text of
/// the entry.
private struct TranscriptRow: Equatable {
    /// The wire id of the entry.
    let wireID: FoundationModelsACP.SessionEntry.ID?

    /// The text of a message or a thought, or `nil` for another kind.
    let text: String?
}

extension TranscriptEntry {
    /// The identity of the object of the entry. Two values with the same
    /// identity hold the same object.
    fileprivate var objectIdentity: ObjectIdentifier {
        switch self {
        case .userMessage(let entry): ObjectIdentifier(entry)
        case .agentMessage(let entry): ObjectIdentifier(entry)
        case .thought(let entry): ObjectIdentifier(entry)
        case .toolCall(let entry): ObjectIdentifier(entry)
        case .terminal(let entry): ObjectIdentifier(entry)
        case .plan(let entry): ObjectIdentifier(entry)
        case .unknown(let entry): ObjectIdentifier(entry)
        case .compaction(let entry): ObjectIdentifier(entry)
        case .sessionMessage(let entry): ObjectIdentifier(entry)
        case .error(let entry): ObjectIdentifier(entry)
        }
    }
}

extension SessionModel {
    /// The identity of the object of each transcript entry, in order.
    fileprivate var transcriptObjects: [ObjectIdentifier] {
        transcript.map(\.objectIdentity)
    }

    /// The rows of the transcript, in order.
    fileprivate var transcriptRows: [TranscriptRow] {
        transcript.map { entry in
            let text: String? =
                switch entry {
                case .userMessage(let message): message.content.joinedText
                case .agentMessage(let message): message.content.joinedText
                case .thought(let thought): thought.content.joinedText
                default: nil
                }
            return TranscriptRow(wireID: entry.wireID, text: text)
        }
    }
}

/// The tests of the read-only model of a share snapshot.
@MainActor
@Suite
struct SessionModelReadOnlyTests {
    @Test func aModelFromASnapshotShowsTheTranscriptOfALiveModelWithTheSameUpdates() {
        let live = SessionModelFixtures.immediateModel()
        live.applyEach(ReadOnlyFixtures.firstTurns)

        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns), sessionId: testSession)

        #expect(shared.transcriptRows == live.transcriptRows)
    }

    @Test func aModelFromASnapshotIsReadOnly() {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns), sessionId: testSession)

        #expect(shared.isReadOnly)
    }

    @Test func aModelOfAConnectionIsNotReadOnly() {
        let connection = ConnectionModel(coalescingCadence: .zero)

        let session = connection.makeSessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())

        #expect(!session.isReadOnly)
    }

    @Test func theTitleOfAModelFromASnapshotIsTheTitleOfTheShare() {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns), sessionId: testSession)

        #expect(shared.sessionInfo.title.currentValue == shareTitle)
    }

    @Test func anEntryOfASnapshotHasNoStartTime() {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns), sessionId: testSession)

        #expect(shared.transcript.allSatisfy { $0.timing.startedAt == nil })
    }

    // MARK: - Requests

    /// The sender of the read-only model of each request test.
    let sender = RecordingSessionRequestSender()

    @Test func aPromptOnAReadOnlyModelThrowsReadOnly() async {
        let shared = ReadOnlyFixtures.readOnlyModel(sender: sender)

        await #expect(throws: SessionModelError.readOnly) { try await shared.prompt([textBlock("Hello")]) }
    }

    @Test func aPromptOnAReadOnlyModelSendsNothing() async {
        let shared = ReadOnlyFixtures.readOnlyModel(sender: sender)

        _ = try? await shared.prompt([textBlock("Hello")])

        #expect(sender.sentMethods.elements.isEmpty)
    }

    @Test func aPromptOnAReadOnlyModelAddsNoEntry() async {
        let shared = ReadOnlyFixtures.readOnlyModel(sender: sender)
        let before = shared.transcriptRows

        _ = try? await shared.prompt([textBlock("Hello")])

        #expect(shared.transcriptRows == before)
    }

    @Test func aCancelOnAReadOnlyModelThrowsReadOnly() async {
        let shared = ReadOnlyFixtures.readOnlyModel(sender: sender)

        await #expect(throws: SessionModelError.readOnly) { try await shared.cancel() }
    }

    @Test func aCancelOnAReadOnlyModelSendsNothing() async {
        let shared = ReadOnlyFixtures.readOnlyModel(sender: sender)

        try? await shared.cancel()

        #expect(sender.sentMethods.elements.isEmpty)
    }

    @Test func aSetModeOnAReadOnlyModelThrowsReadOnly() async {
        let shared = ReadOnlyFixtures.readOnlyModel(sender: sender)

        await #expect(throws: SessionModelError.readOnly) {
            try await shared.setConfigOption(ReadOnlyFixtures.setModeRequest)
        }
    }

    @Test func aSetModeOnAReadOnlyModelSendsNothing() async {
        let shared = ReadOnlyFixtures.readOnlyModel(sender: sender)

        try? await shared.setConfigOption(ReadOnlyFixtures.setModeRequest)

        #expect(sender.sentMethods.elements.isEmpty)
    }

    // MARK: - Replace

    @Test func aReplaceWithTwoMoreTurnsShowsTheNewerTranscript() throws {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns), sessionId: testSession)
        let newer = ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.fourTurns)

        try shared.replace(with: newer)

        #expect(shared.transcriptRows == SessionModel(snapshot: newer, sessionId: testSession).transcriptRows)
    }

    @Test func aReplaceWithTwoMoreTurnsKeepsTheObjectOfEachOldEntry() throws {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns), sessionId: testSession)
        let before = shared.transcriptObjects

        try shared.replace(with: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.fourTurns))

        #expect(Array(shared.transcriptObjects.prefix(before.count)) == before)
    }

    @Test func aReplaceWithTwoMoreTurnsKeepsTheIdOfEachOldEntry() throws {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns), sessionId: testSession)
        let before = shared.transcript.map(\.id)

        try shared.replace(with: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.fourTurns))

        #expect(Array(shared.transcript.map(\.id).prefix(before.count)) == before)
    }

    @Test func aReplaceChangesAChangedEntryInPlace() throws {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.partialAnswer), sessionId: testSession)
        let before = shared.transcriptObjects

        try shared.replace(with: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.completeAnswer))

        #expect(shared.transcriptObjects == before)
    }

    @Test func aReplaceGivesAChangedEntryItsNewerText() throws {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.partialAnswer), sessionId: testSession)

        try shared.replace(with: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.completeAnswer))

        #expect(shared.transcriptRows.last?.text == "Hello")
    }

    @Test func aReplaceWithADifferentStartShowsTheNewerTranscript() throws {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.turn(1)), sessionId: testSession)
        let newer = ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.turn(2))

        try shared.replace(with: newer)

        #expect(shared.transcriptRows == SessionModel(snapshot: newer, sessionId: testSession).transcriptRows)
    }

    @Test func aReplaceWithFewerEntriesShowsTheNewerTranscript() throws {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.fourTurns), sessionId: testSession)
        let newer = ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns)

        try shared.replace(with: newer)

        #expect(shared.transcriptRows == SessionModel(snapshot: newer, sessionId: testSession).transcriptRows)
    }

    @Test func aReplaceSetsTheTitleOfTheNewerShare() throws {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns), sessionId: testSession)
        let newer = SessionSnapshot.build(updates: ReadOnlyFixtures.fourTurns, options: .init(title: "Renamed"))

        try shared.replace(with: newer)

        #expect(shared.sessionInfo.title.currentValue == "Renamed")
    }

    @Test func aReplaceWithNoTitleClearsTheTitle() throws {
        let shared = SessionModel(snapshot: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns), sessionId: testSession)

        try shared.replace(with: SessionSnapshot.build(updates: ReadOnlyFixtures.fourTurns))

        #expect(shared.sessionInfo.title.currentValue == nil)
    }

    @Test func aReplaceOnAModelOfAConnectionThrowsNotReadOnly() {
        let live = SessionModelFixtures.immediateModel()

        #expect(throws: SessionModelError.notReadOnly) {
            try live.replace(with: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.firstTurns))
        }
    }

    @Test func aReplaceOnAModelOfAConnectionChangesNothing() {
        let live = SessionModelFixtures.immediateModel()
        live.applyEach(ReadOnlyFixtures.turn(1))
        let before = live.transcriptRows

        try? live.replace(with: ReadOnlyFixtures.snapshot(of: ReadOnlyFixtures.fourTurns))

        #expect(live.transcriptRows == before)
    }
}
