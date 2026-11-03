import FoundationModelsACP
import Observation
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// The tests of the child sessions across `session/resume`. The agent sends
// all history of the tree before the resume response. The response ends the
// replay of each child model. A snapshot before the response is history: it
// authorizes nothing and confirms nothing. A child stays unconfirmed after
// the response until its first current snapshot. A finished child is removed
// when its linked tool call reaches a final status.

/// The ids of the child sessions of the tests.
let firstChild = SessionId(rawValue: "child-1")
let secondChild = SessionId(rawValue: "child-2")

/// The tool call that started the first child.
let agentsCall = ToolCallId(rawValue: "agents-call-1")

/// The capabilities that allow a cancel of a child.
let cancelCapabilities = SubagentSessionCapabilities(cancel: SessionCancelCapabilities())

/// Makes a `subagent_update` snapshot of a child.
///
/// - Parameters:
///   - child: The id of the child.
///   - state: The state of the snapshot, or `.unchanged`.
///   - capabilities: The capabilities of the snapshot, or `.unchanged`.
///   - toolCall: The tool call that started the child, or `nil` for no link.
///   - meta: The `_meta` of the snapshot when `toolCall` is `nil`.
/// - Returns: The update.
func snapshot(
    _ child: SessionId,
    state: PatchField<StateUpdate> = .unchanged,
    capabilities: PatchField<SubagentSessionCapabilities> = .unchanged,
    toolCall: ToolCallId? = nil,
    meta: PatchField<JSONValue> = .unchanged
) throws -> SessionUpdate {
    let linked: PatchField<JSONValue> =
        if let toolCall { .value(try SAH.AgentRun(toolCallId: toolCall).inject(into: nil)) } else { meta }
    return .subagentUpdate(
        SubagentUpdate(sessionId: child, capabilities: capabilities, state: state, meta: linked)
    )
}

/// A stub agent that serves `session/resume` by running a script on its
/// connection, and then answers.
final class ResumeStubAgent: BaselineStubAgent, UpdateSendingStubAgent {
    /// The connection back to the client.
    let connection: AgentSideConnection

    /// What the stub sends as the replay of the next `session/resume`, before
    /// its answer.
    private let replay: Mutex<@Sendable (AgentSideConnection) async throws -> Void>

    /// A gate that the stub waits on after the replay and before the answer,
    /// or `nil` for no wait.
    private let beforeAnswer: Mutex<UpdateGate?>

    /// The error that the stub answers `session/resume` with, or `nil`.
    private let resumeError: Mutex<RequestError?>

    /// What the stub does at once after the answer of `session/resume`, or
    /// `nil`.
    private let afterAnswer: Mutex<(@Sendable (AgentSideConnection) async -> Void)?>

    /// The input side of ``cancels``.
    private let cancelInput: AsyncStream<CancelSessionNotification>.Continuation

    /// Each `session/cancel` that the stub got.
    let cancels: AsyncStream<CancelSessionNotification>

    init(connection: AgentSideConnection) {
        self.connection = connection
        replay = Mutex { _ in }
        beforeAnswer = Mutex(nil)
        resumeError = Mutex(nil)
        afterAnswer = Mutex(nil)
        (cancels, cancelInput) = AsyncStream.makeStream()
    }

    /// Sets what the next resume replays.
    func setReplay(_ script: @escaping @Sendable (AgentSideConnection) async throws -> Void) {
        replay.withLock { $0 = script }
    }

    /// Sets a gate that holds the resume answer.
    func setGate(_ gate: UpdateGate?) {
        beforeAnswer.withLock { $0 = gate }
    }

    /// Sets the error that the next resume answers with.
    func setResumeError(_ error: RequestError?) {
        resumeError.withLock { $0 = error }
    }

    /// Sets what the stub does at once after the answer of the next resume.
    func setAfterAnswer(_ work: @escaping @Sendable (AgentSideConnection) async -> Void) {
        afterAnswer.withLock { $0 = work }
    }

    /// Sends one update.
    func send(_ update: SessionUpdate, to sessionId: SessionId = testSession) async throws {
        try await connection.sessionUpdate(UpdateSessionNotification(sessionId: sessionId, update: update))
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: testSession)
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        let script = replay.withLock { $0 }
        try await script(connection)
        await beforeAnswer.withLock { $0 }?.wait()
        if let error = resumeError.withLock({ $0 }) {
            throw error
        }
        if let work = afterAnswer.withLock({ $0 }) {
            let connection = connection
            connection.afterRespondingToCurrentRequest { await work(connection) }
        }
        return ResumeSessionResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {
        cancelInput.yield(params)
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        throw RequestError.methodNotFound(ClientRequestSpan.Method.prompt)
    }
}

/// A model that is connected to a resume stub agent, with one open root
/// session.
@MainActor
struct ResumeConnection {
    let connected: ConnectedStub<ResumeStubAgent>

    var model: ConnectionModel { connected.model }
    var agent: ResumeStubAgent { connected.agent }
    var root: SessionModel { connected.root }

    /// Connects the model and opens the root session.
    ///
    /// - Throws: The error of `initialize` or of `session/new`.
    static func make(bufferLimits: SessionUpdateBufferLimits = .default) async throws -> Self {
        Self(connected: try await ConnectedStub.make(bufferLimits: bufferLimits) { ResumeStubAgent(connection: $0) })
    }

    /// Sends a live snapshot and waits until the model made the child.
    @discardableResult
    func announce(_ update: SessionUpdate, child sessionId: SessionId) async throws -> SessionModel {
        try await connected.announce(update, child: sessionId)
    }

    /// The resume request of the test session.
    func resume(replayFrom: ReplayFrom?) async throws -> SessionModel {
        try await model.resumeSession(
            ResumeSessionRequest(cwd: AbsolutePath(rawValue: "/"), sessionId: testSession, replayFrom: replayFrom)
        )
    }
}

/// The resume tests, in one suite so that `swift test --filter
/// SubagentResumeTests` selects them.
@MainActor
struct SubagentResumeTests {
    // MARK: - Replay phase

    @Test func aChildMadeDuringAReplayIsReplayingUntilTheResponse() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let gate = UpdateGate()
        connected.agent.setGate(gate)
        connected.agent.setReplay { connection in
            let update = try snapshot(firstChild, state: .value(.running(RunningStateUpdate())))
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }

        let resume = Task { try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart) }
        try await waitForObservation { childModel(firstChild, under: connected.root) != nil } orFailWhen: { resume.isCancelled }
        let child = try #require(childModel(firstChild, under: connected.root))
        #expect(child.isReplaying)

        gate.open()
        _ = try await resume.value
        #expect(!child.isReplaying)
    }

    @Test func aSnapshotBeforeTheResponseIsHistoryAndAuthorizesNothing() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let gate = UpdateGate()
        connected.agent.setGate(gate)
        connected.agent.setReplay { connection in
            let update = try snapshot(
                firstChild,
                state: .value(.running(RunningStateUpdate())),
                capabilities: .value(cancelCapabilities)
            )
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }

        let resume = Task { try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart) }
        try await waitForObservation { childModel(firstChild, under: connected.root) != nil } orFailWhen: { resume.isCancelled }
        let child = try #require(childModel(firstChild, under: connected.root))

        #expect(child.capabilities == nil)
        #expect(child.workState == .unknown)
        #expect(!child.isWorkStateConfirmed)
        gate.open()
        _ = try await resume.value
    }

    @Test func replayedHistoryRaisesNoNeedsAttention() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        connected.agent.setReplay { connection in
            let update = try snapshot(firstChild, state: .value(.requiresAction(RequiresActionStateUpdate())))
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }

        _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)
        let child = try #require(childModel(firstChild, under: connected.root))

        #expect(!child.needsAttention)
        #expect(!connected.root.needsAttention)
        #expect(connected.root.notices.isEmpty)
    }

    // MARK: - Confirmation

    @Test func aChildIsUnconfirmedAfterTheResponseUntilItsFirstCurrentSnapshot() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        connected.agent.setReplay { connection in
            let update = try snapshot(firstChild, state: .value(.running(RunningStateUpdate())))
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }
        _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)
        let child = try #require(childModel(firstChild, under: connected.root))

        #expect(!child.isWorkStateConfirmed)
        #expect(child.workState == .unknown)
        #expect(child.capabilities == nil)
        await #expect(throws: SubagentSessionError.notPermitted(operation: ClientRequestSpan.Method.cancelSession)) {
            try await child.cancel()
        }
    }

    @Test func theFirstCurrentSnapshotConfirmsTheChildWithTheNewCapabilities() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        connected.agent.setReplay { connection in
            let update = try snapshot(firstChild)
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }
        _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)
        let child = try #require(childModel(firstChild, under: connected.root))

        try await connected.agent.send(
            try snapshot(firstChild, state: .value(.running(RunningStateUpdate())), capabilities: .value(cancelCapabilities))
        )
        try await waitForObservation { child.isWorkStateConfirmed } orFailWhen: { connected.root.isClosed }

        #expect(child.workState == .running)
        #expect(child.capabilities == cancelCapabilities)
    }

    @Test func aCurrentSnapshotThatOmitsTheStateDoesNotShowTheHistoryState() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        connected.agent.setReplay { connection in
            let update = try snapshot(
                firstChild,
                state: .value(.running(RunningStateUpdate())),
                capabilities: .value(cancelCapabilities)
            )
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }
        _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)
        let child = try #require(childModel(firstChild, under: connected.root))

        try await connected.agent.send(try snapshot(firstChild))
        try await waitForObservation { child.isWorkStateConfirmed } orFailWhen: { connected.root.isClosed }

        #expect(child.workState == .unknown)
        #expect(child.capabilities == nil)
    }

    @Test func aCurrentSnapshotWithNoTitleKeepsTheTitleOfTheReplay() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        connected.agent.setReplay { connection in
            let update = SessionUpdate.subagentUpdate(
                SubagentUpdate(sessionId: firstChild, title: .value("Reviewer"))
            )
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }
        _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)
        let child = try #require(childModel(firstChild, under: connected.root))

        try await connected.agent.send(try snapshot(firstChild, state: .value(.running(RunningStateUpdate()))))
        try await waitForObservation { child.isWorkStateConfirmed } orFailWhen: { connected.root.isClosed }

        #expect(child.title == "Reviewer")
        #expect(child.displayTitle == "Reviewer")
    }

    @Test func aSnapshotBeforeTheResponseOfAResumeWithNoReplayIsCurrent() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        connected.agent.setReplay { connection in
            let update = try snapshot(
                firstChild,
                state: .value(.running(RunningStateUpdate())),
                capabilities: .value(cancelCapabilities)
            )
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }

        _ = try await connected.resume(replayFrom: nil)

        let child = try #require(childModel(firstChild, under: connected.root))
        #expect(child.isWorkStateConfirmed)
        #expect(child.workState == .running)
        #expect(child.capabilities == cancelCapabilities)
    }

    @Test func aResumeWithNoReplayRemovesAStaleChildWhoseToolCallIsFinal() async throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(toolCallStatus(id: agentsCall.rawValue, .completed))
        let stale = SessionModelFixtures.immediateModel()
        stale.startedByToolCallId = agentsCall
        model.addChild(stale)

        model.beginReplay(replayFrom: nil)
        model.endReplay(succeeded: true)

        #expect(model.children.isEmpty)
        #expect(stale.isClosed)
    }

    @Test func aResumeWithNoReplayKeepsAStaleChildWhoseToolCallIsNotFinal() async throws {
        let model = SessionModelFixtures.immediateModel()
        model.apply(toolCallStatus(id: agentsCall.rawValue, .inProgress))
        let stale = SessionModelFixtures.immediateModel()
        stale.startedByToolCallId = agentsCall
        model.addChild(stale)

        model.beginReplay(replayFrom: nil)
        model.endReplay(succeeded: true)

        #expect(model.children.count == 1)
        #expect(!stale.isClosed)
        #expect(!stale.isWorkStateConfirmed)
    }

    @Test func aFailedResumeOfAnOpenSessionRestoresTheTranscriptAndTheChildren() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        try await connected.agent.send(agentChunk(text: "before", message: "root-before"))
        let child = try await connected.announce(try snapshot(firstChild), child: firstChild)
        try await waitForObservation { !connected.root.transcript.isEmpty } orFailWhen: { connected.root.isClosed }
        let transcriptBefore = connected.root.transcript.map(\.id)
        connected.agent.setReplay { connection in
            let update = agentChunk(text: "replayed", message: "root-replayed")
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }
        connected.agent.setResumeError(RequestError.internalError(detail: "no"))

        await #expect(throws: (any Error).self) {
            _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)
        }

        #expect(connected.root.transcript.map(\.id) == transcriptBefore)
        #expect(connected.root.children.first === child)
        #expect(!child.isClosed)
        #expect(childModel(firstChild, under: connected.root) === child)
        // The old child still gets its events.
        try await connected.agent.send(agentChunk(text: "after", message: "child-after"), to: firstChild)
        try await waitForObservation { !child.transcript.isEmpty } orFailWhen: { connected.root.isClosed }
    }

    @Test func aLiveStateUpdateOfTheChildDoesNotConfirmIt() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        connected.agent.setReplay { connection in
            let update = try snapshot(firstChild)
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }
        _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)
        let child = try #require(childModel(firstChild, under: connected.root))

        try await connected.agent.send(.stateUpdate(.running(RunningStateUpdate())), to: firstChild)
        try await connected.agent.send(agentChunk(text: "mark", message: "m-1"), to: firstChild)
        try await waitForObservation { !child.transcript.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(!child.isWorkStateConfirmed)
    }

    @Test func aLiveChildIsConfirmedByItsFirstAnnouncement() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }

        let child = try await connected.announce(
            try snapshot(firstChild, state: .value(.running(RunningStateUpdate()))),
            child: firstChild
        )

        #expect(child.isWorkStateConfirmed)
    }

    // MARK: - Resume without replay

    @Test func aResumeWithNoReplayFromKeepsTheChildModelsAndInvalidatesTheirState() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(
            try snapshot(firstChild, state: .value(.running(RunningStateUpdate())), capabilities: .value(cancelCapabilities)),
            child: firstChild
        )

        _ = try await connected.resume(replayFrom: nil)

        #expect(connected.root.children.first === child)
        #expect(!child.isClosed)
        #expect(!child.isWorkStateConfirmed)
        #expect(child.capabilities == nil)
        #expect(child.workState == .unknown)
    }

    @Test func aResumeWithNoReplayFromConfirmsAChildAtItsCurrentSnapshot() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(try snapshot(firstChild), child: firstChild)
        connected.agent.setReplay { connection in
            let update = try snapshot(firstChild, state: .value(.idle(IdleStateUpdate())), capabilities: .value(cancelCapabilities))
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }

        _ = try await connected.resume(replayFrom: nil)
        try await waitForObservation { child.isWorkStateConfirmed } orFailWhen: { connected.root.isClosed }

        #expect(child.capabilities == cancelCapabilities)
    }

    // MARK: - Rebuild

    @Test func aResumeWithReplayClosesTheOldChildModelsAndRebuildsFromTheAnnouncements() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let gone = try await connected.announce(try snapshot(firstChild), child: firstChild)
        let kept = try await connected.announce(try snapshot(secondChild), child: secondChild)
        connected.agent.setReplay { connection in
            let update = try snapshot(secondChild)
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }

        _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)

        #expect(gone.isClosed)
        #expect(kept.isClosed)
        #expect(connected.root.children.map(\.id) == [secondChild])
        #expect(connected.root.children.first !== kept)
    }

    // MARK: - Removal

    @Test func aChildIsRemovedWhenItsLinkedToolCallFinishes() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(try snapshot(firstChild, toolCall: agentsCall), child: firstChild)
        try await connected.agent.send(toolCallStatus(id: agentsCall.rawValue, .inProgress))

        try await connected.agent.send(toolCallStatus(id: agentsCall.rawValue, .completed))
        try await waitForObservation { child.isClosed } orFailWhen: { connected.root.isClosed }

        #expect(connected.root.children.isEmpty)
    }

    @Test func theToolCallEntryForgetsAChildThatWasRemoved() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(try snapshot(firstChild, toolCall: agentsCall), child: firstChild)
        let link = try SAH.AgentRun(sessionId: firstChild).inject(into: nil)
        try await connected.agent.send(
            .toolCallUpdate(ToolCallUpdate(toolCallId: agentsCall, status: .value(.inProgress), meta: .value(link)))
        )
        try await waitForObservation { connected.root.transcript.first?.toolCall?.childSession === child } orFailWhen: {
            connected.root.isClosed
        }

        try await connected.agent.send(toolCallStatus(id: agentsCall.rawValue, .completed))
        try await waitForObservation { child.isClosed } orFailWhen: { connected.root.isClosed }

        #expect(connected.root.transcript.first?.toolCall?.childSession == nil)
    }

    @Test func aLaterAnnouncementThatNamesAFinishedToolCallRemovesTheChild() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(try snapshot(firstChild), child: firstChild)
        try await connected.agent.send(toolCallStatus(id: agentsCall.rawValue, .completed))

        try await connected.agent.send(try snapshot(firstChild, toolCall: agentsCall))
        try await waitForObservation { child.isClosed } orFailWhen: { connected.root.isClosed }

        #expect(connected.root.children.isEmpty)
    }

    @Test func aChildWithNoLinkIsKeptWhenAToolCallFinishes() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(try snapshot(firstChild), child: firstChild)

        try await connected.agent.send(toolCallStatus(id: agentsCall.rawValue, .completed))
        try await connected.agent.send(agentChunk(text: "mark", message: "root-1"))
        try await waitForObservation { !connected.root.transcript.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(!child.isClosed)
        #expect(connected.root.children.count == 1)
    }

    @Test func noChildTrafficIsAppliedAfterTheRemoval() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(try snapshot(firstChild, toolCall: agentsCall), child: firstChild)
        try await connected.agent.send(toolCallStatus(id: agentsCall.rawValue, .failed))
        try await waitForObservation { child.isClosed } orFailWhen: { connected.root.isClosed }

        try await connected.agent.send(agentChunk(text: "late", message: "late-1"), to: firstChild)
        try await connected.agent.send(agentChunk(text: "mark", message: "root-1"))
        try await waitForObservation { !connected.root.transcript.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(child.transcript.isEmpty)
    }

    @Test func theToolCallEntryNamesItsChildSession() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(try snapshot(firstChild, toolCall: agentsCall), child: firstChild)
        let link = try SAH.AgentRun(sessionId: firstChild).inject(into: nil)

        try await connected.agent.send(
            .toolCallUpdate(ToolCallUpdate(toolCallId: agentsCall, status: .value(.inProgress), meta: .value(link)))
        )
        try await waitForObservation { connected.root.transcript.first?.toolCall != nil } orFailWhen: {
            connected.root.isClosed
        }

        #expect(connected.root.transcript.first?.toolCall?.childSession === child)
        #expect(child.startedByToolCallId == agentsCall)
    }

    @Test func aRemovalFiresTheObservationOfIsClosed() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(try snapshot(firstChild, toolCall: agentsCall), child: firstChild)
        let fired = Mutex(false)
        withObservationTracking {
            _ = child.isClosed
        } onChange: {
            fired.withLock { $0 = true }
        }

        try await connected.agent.send(toolCallStatus(id: agentsCall.rawValue, .cancelled))
        try await waitForObservation { child.isClosed } orFailWhen: { connected.root.isClosed }

        #expect(fired.withLock { $0 })
    }

    // MARK: - Failure

    @Test func aFailedRootReplayEndsTheReplayOfEachChildAndDropsThem() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let gate = UpdateGate()
        connected.agent.setGate(gate)
        connected.agent.setReplay { connection in
            let update = try snapshot(firstChild)
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
        }
        connected.agent.setResumeError(RequestError.internalError(detail: "no"))
        let resume = Task { try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart) }
        let child = try await waitForChild(firstChild, under: connected.root)

        gate.open()
        await #expect(throws: (any Error).self) { _ = try await resume.value }

        // The child of the failed replay is gone, as the whole replay is.
        #expect(!child.isReplaying)
        #expect(child.isClosed)
        #expect(connected.root.children.isEmpty)
    }
}
