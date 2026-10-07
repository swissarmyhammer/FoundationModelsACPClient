import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the base of `ConnectionModel`: the connection state, the
// registry of open sessions, the close of each open session when the
// connection closes, the disconnect that the host starts, and the cadence and
// clock that each session model of the connection gets.
//
// `InMemoryTransport.pair()` gives the real ACP wire. A `close()` on the agent
// end finishes the byte stream of the client end, which is the end of input
// of a dead agent. `FailingTransport` gives a byte stream that throws.
// `EndRecordingTransport` records the end of its byte stream.

/// The error that the failing byte stream throws.
private struct ByteStreamFailure: Error, Equatable {}

/// The step, in milliseconds, between the last instant before the flush
/// deadline and the deadline.
private let clockStepMilliseconds = 1

/// The step between the last instant before the flush deadline and the
/// deadline.
private let clockStep: Duration = .milliseconds(clockStepMilliseconds)

extension ConnectionState {
    /// The error of a failed state, or `nil` for each other state.
    fileprivate var failure: (any Error)? {
        guard case .failed(let error) = self else { return nil }
        return error
    }
}

/// A transport whose byte stream fails when the test calls ``fail(with:)``.
///
/// A write goes nowhere: the tests of this file send no request.
private struct FailingTransport: ACPTransport {
    /// The incoming bytes. No chunk arrives; the stream ends only with the
    /// failure.
    let bytes: AsyncThrowingStream<Data, any Error>

    /// The continuation of ``bytes``.
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    /// Makes a transport whose byte stream is open.
    init() {
        (bytes, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    }

    /// Ends the byte stream with an error.
    ///
    /// - Parameter error: The error that the byte stream throws.
    func fail(with error: any Error) {
        continuation.finish(throwing: error)
    }

    /// Drops the bytes.
    ///
    /// - Parameter data: The bytes to send.
    func write(_ data: Data) async throws {}
}

/// A transport that records the end of its byte stream.
///
/// The connection stops its read of ``bytes`` when it closes. That stop ends
/// the stream, as the end of the stream of an `AgentProcess` transport ends
/// the agent process. A write goes nowhere.
private struct EndRecordingTransport: ACPTransport {
    /// The incoming bytes. No chunk arrives.
    let bytes: AsyncThrowingStream<Data, any Error>

    /// One item for each end of ``bytes``.
    private let ends = ThreadSafeBuffer<Bool>()

    /// Whether the byte stream ended.
    var hasEnded: Bool {
        !ends.elements.isEmpty
    }

    /// Makes a transport whose byte stream is open.
    init() {
        let (bytes, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.bytes = bytes
        continuation.onTermination = { [ends] _ in ends.append(true) }
    }

    /// Drops the bytes.
    ///
    /// - Parameter data: The bytes to send.
    func write(_ data: Data) async throws {}
}

/// Records the connection states that a test reads at given times.
@MainActor
private final class StateRecorder {
    /// The recorded states, in the order of the reads.
    private(set) var states: [ConnectionState] = []

    /// Records one state.
    ///
    /// - Parameter state: The state to record.
    func record(_ state: ConnectionState) {
        states.append(state)
    }
}

/// A `Client` that answers each permission request with the "allow" option
/// and forwards each other call to the client that it wraps.
///
/// The tests use it to prove which `Client` the connection serves.
private struct AllowingClient: Client {
    /// The client that this wrapper stands in front of.
    let inner: any Client

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        await inner.sessionUpdate(notification)
    }

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        RequestPermissionResponse(
            outcome: .selected(SelectedPermissionOutcome(optionId: SessionModelFixtures.allowOption.optionId))
        )
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        try await inner.createElicitation(params)
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        await inner.elicitationComplete(notification)
    }
}

/// The connection model tests, in one suite so that `swift test --filter
/// ConnectionModelTests` selects them. A wait for a close that never comes
/// would suspend for ever, so the suite has a time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionModelTests {
    /// The working directory of the session that a test opens over the wire.
    private let workingDirectory = AbsolutePath(rawValue: "/")

    /// Makes the agent side of a pair: a stub agent over `agentEnd`.
    ///
    /// - Parameter agentEnd: The agent end of the pair.
    /// - Returns: The agent-side connection.
    private func makeAgentConnection(over agentEnd: InMemoryTransport) async -> AgentSideConnection {
        await AgentSideConnection(stream: agentEnd) { connection in
            ScriptedStubAgent(connection: connection, session: testSession, script: [])
        }
    }

    // MARK: - State

    @Test func aNewModelIsDisconnected() {
        #expect(ConnectionModel().state == .disconnected)
    }

    @Test func connectIsConnectingWhileItMakesTheConnection() async {
        let model = ConnectionModel()
        let recorder = StateRecorder()
        let (clientEnd, _) = InMemoryTransport.pair()

        _ = await model.connect(over: clientEnd) { [model, recorder] router in
            recorder.record(model.state)
            return router
        }

        #expect(recorder.states == [.connecting])
    }

    @Test func connectIsConnectedWhenItReturns() async {
        let model = ConnectionModel()
        let (clientEnd, _) = InMemoryTransport.pair()

        _ = await model.connect(over: clientEnd)

        #expect(model.state == .connected)
    }

    @Test func theEndOfInputOfTheAgentDisconnects() async {
        let model = ConnectionModel()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        _ = await model.connect(over: clientEnd)

        agentEnd.close()

        #expect(await eventually { model.state == .disconnected })
    }

    @Test func aCloseByTheHostDisconnects() async {
        let model = ConnectionModel()
        let (clientEnd, _) = InMemoryTransport.pair()
        let connection = await model.connect(over: clientEnd)

        await connection.close()

        #expect(await eventually { model.state == .disconnected })
    }

    @Test func aFailedByteStreamFailsWithItsError() async {
        let model = ConnectionModel()
        let transport = FailingTransport()
        _ = await model.connect(over: transport)

        transport.fail(with: ByteStreamFailure())

        #expect(await eventually { model.state == .failed(ByteStreamFailure()) })
        #expect(model.state.failure is ByteStreamFailure)
    }

    @Test func twoFailedStatesAreEqualForEachError() {
        struct OtherFailure: Error {}

        #expect(ConnectionState.failed(ByteStreamFailure()) == .failed(OtherFailure()))
        #expect(ConnectionState.failed(ByteStreamFailure()) != .disconnected)
    }

    // MARK: - Client

    @Test func theConnectionServesTheRouterThatAnswersCancelled() async throws {
        let model = ConnectionModel()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await makeAgentConnection(over: agentEnd)
        _ = await model.connect(over: clientEnd)

        let response = try await agentConnection.requestPermission(SessionModelFixtures.permissionRequest())

        #expect(response.outcome == .cancelled)
    }

    @Test func theConnectionServesTheClientThatTheWrapReturns() async throws {
        let model = ConnectionModel()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await makeAgentConnection(over: agentEnd)
        _ = await model.connect(over: clientEnd) { router in AllowingClient(inner: router) }

        let response = try await agentConnection.requestPermission(SessionModelFixtures.permissionRequest())

        #expect(response.outcome == .selected(SelectedPermissionOutcome(optionId: SessionModelFixtures.allowOption.optionId)))
    }

    // MARK: - Open sessions

    @Test func aRegisteredSessionIsOpen() {
        let model = ConnectionModel()
        let session = SessionModelFixtures.immediateModel()

        model.register(session)

        #expect(model.session(for: testSession) === session)
        #expect(Array(model.openSessions.keys) == [testSession])
    }

    @Test func anUnregisteredSessionIsNotOpen() {
        let model = ConnectionModel()
        model.register(SessionModelFixtures.immediateModel())

        model.unregister(testSession)

        #expect(model.session(for: testSession) == nil)
        #expect(model.openSessions.isEmpty)
    }

    @Test func aDisconnectClosesEachOpenSessionAndCancelsItsPendingPermission() async throws {
        let model = ConnectionModel()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        _ = await model.connect(over: clientEnd)
        let session = SessionModelFixtures.immediateModel()
        model.register(session)
        let permission = try await SessionModelFixtures.startPermission(on: session)

        agentEnd.close()

        let response = await permission.value
        #expect(response.outcome == .cancelled)
        #expect(await eventually { model.state == .disconnected })
        #expect(session.isClosed)
        #expect(session.pendingPermissions.isEmpty)
        #expect(model.openSessions.isEmpty)
    }

    @Test func aDisconnectFlushesTheBufferedChunksOfEachOpenSession() async throws {
        let model = ConnectionModel(coalescingCadence: SessionModelFixtures.bufferedCadence, clock: ManualClock())
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        _ = await model.connect(over: clientEnd)
        let first = model.makeSessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())
        let second = model.makeSessionModel(sessionId: otherTestSession, requestSender: FakeSessionRequestSender())
        model.register(first)
        model.register(second)
        first.apply(agentChunk(text: "left open"))
        second.apply(agentChunk(text: "also open", message: "agent-2"))
        // The manual clock never moves, so only the disconnect can flush.
        try #require(first.transcript.isEmpty && second.transcript.isEmpty)

        agentEnd.close()

        #expect(await eventually { model.state == .disconnected })
        #expect(try #require(first.transcript.first?.agentMessage).content.joinedText == "left open")
        #expect(try #require(second.transcript.first?.agentMessage).content.joinedText == "also open")
    }

    @Test func aDisconnectCancelsEachSessionScopedElicitation() async throws {
        let model = ConnectionModel()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        _ = await model.connect(over: clientEnd)
        let session = SessionModelFixtures.immediateModel()
        model.register(session)
        let request = ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))
        let elicitation = Task { await session.awaitElicitation(request) }
        try await waitUntil { !session.pendingElicitations.isEmpty }

        agentEnd.close()

        #expect(await elicitation.value == ElicitationResponseWire.cancelResponse)
        #expect(session.pendingElicitations.isEmpty)
    }

    @Test func aFailureClosesEachOpenSession() async {
        let model = ConnectionModel()
        let transport = FailingTransport()
        _ = await model.connect(over: transport)
        let session = SessionModelFixtures.immediateModel()
        model.register(session)

        transport.fail(with: ByteStreamFailure())

        #expect(await eventually { model.state == .failed(ByteStreamFailure()) })
        #expect(session.isClosed)
        #expect(model.openSessions.isEmpty)
    }

    // MARK: - Disconnect

    @Test func disconnectSetsDisconnectedAndClosesOpenSessions() async throws {
        let connected = await ConnectedModel()
        try await connected.initialize()
        let session = try await connected.model.newSession(NewSessionRequest(cwd: workingDirectory))

        await connected.model.disconnect()

        // The call returns only after the close, so the state is final at once.
        #expect(connected.model.state == .disconnected)
        #expect(connected.model.openSessions.isEmpty)
        #expect(session.isClosed)
    }

    @Test func disconnectCancelsPendingPermissions() async throws {
        let connected = await ConnectedModel()
        try await connected.initialize()
        let session = try await connected.model.newSession(NewSessionRequest(cwd: workingDirectory))
        let permission = try await SessionModelFixtures.startPermission(on: session)

        await connected.model.disconnect()

        #expect(session.pendingPermissions.isEmpty)
        #expect(await permission.value.outcome == .cancelled)
    }

    @Test func disconnectClosesTheTransport() async throws {
        let model = ConnectionModel()
        let transport = EndRecordingTransport()
        _ = await model.connect(over: transport)

        await model.disconnect()

        // The read of the bytes stops in a task of the connection, so the
        // end can come a short time after the close.
        try await waitUntil { transport.hasEnded }
        #expect(model.state == .disconnected)
    }

    @Test func disconnectTwiceOrWithNoConnectionChangesNothing() async {
        let unconnected = ConnectionModel()
        let unconnectedSession = SessionModelFixtures.immediateModel()
        unconnected.register(unconnectedSession)
        let connected = await ConnectedModel()
        await connected.model.disconnect()
        let laterSession = SessionModelFixtures.immediateModel()
        connected.model.register(laterSession)

        await unconnected.disconnect()
        await connected.model.disconnect()

        #expect(unconnected.state == .disconnected)
        #expect(unconnected.session(for: testSession) === unconnectedSession)
        #expect(!unconnectedSession.isClosed)
        #expect(connected.model.state == .disconnected)
        #expect(connected.model.session(for: testSession) === laterSession)
        #expect(!laterSession.isClosed)
    }

    @Test func connectAfterDisconnectWorks() async throws {
        let connected = await ConnectedModel()
        try await connected.initialize()
        await connected.model.disconnect()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await makeAgentConnection(over: agentEnd)

        _ = await connected.model.connect(over: clientEnd)
        let response = try await connected.model.initialize(makeInitializeRequest())

        #expect(connected.model.state == .connected)
        #expect(connected.model.initializeResponse == response)
        // The test holds the agent end of the new pair until here.
        withExtendedLifetime(agentConnection) {}
    }

    // MARK: - Session models

    @Test func aSessionModelOfTheConnectionUsesItsCadenceAndClock() async {
        let clock = ManualClock()
        let model = ConnectionModel(coalescingCadence: SessionModelFixtures.bufferedCadence, clock: clock)
        let session = model.makeSessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())

        session.apply(agentChunk(text: "one"))
        await yieldUntil { clock.sleeperCount > 0 }
        clock.advance(by: SessionModelFixtures.bufferedCadence - clockStep)

        // The flush waits on the manual clock for the whole given cadence.
        #expect(clock.sleeperCount == 1)
        #expect(session.transcript.isEmpty)

        clock.advance(by: clockStep)
        await yieldUntil { !session.transcript.isEmpty }
        #expect(session.transcript.count == 1)
    }
}
