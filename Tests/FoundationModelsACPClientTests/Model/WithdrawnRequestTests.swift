import FoundationModelsACP
import Observation
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// The tests of `withdrawnRequests`: a pending request that the agent withdraws
// with `$/cancel_request` leaves `pendingRequests`, and a record with the
// reason of the agent comes into `withdrawnRequests`. A close of the transport
// also cancels the task of each request, and it must make no record.
//
// Each test fixes the order: the agent sends each request itself through
// `MailOrderStubAgent`, and the test waits on the observable state of the
// model. No test waits on a clock.
//
// Each wait has a failure event (rule T1). A wait for a pending request ends
// also on the close of the session, or on the end of the call of the agent: a
// call that ended before the request is pending tells that the request never
// comes. A wait for a record ends also on the close of the session. Each test
// closes the connection in a `defer`, so the close runs also when the test
// body throws.

/// The reason that the tests give in the `_meta` of the `$/cancel_request`.
private let runCancelledReason = "run cancelled"

/// A connection model that is connected over an in-memory pair to a
/// ``MailOrderStubAgent``, with one open session.
@MainActor
private struct WithdrawalSession {
    /// The model under test.
    let model: ConnectionModel

    /// The agent-side connection. The test holds it so that the agent end of
    /// the pair outlives the test body.
    let agentConnection: AgentSideConnection

    /// The agent end of the pair. A close of it ends the input of the client.
    let agentEnd: InMemoryTransport

    /// The stub agent.
    let agent: MailOrderStubAgent

    /// The open session.
    let session: SessionModel

    /// Connects a model, initializes it, and opens one session.
    ///
    /// When a step fails, the init closes the connection before it throws.
    ///
    /// - Throws: The error of `initialize` or of `session/new`.
    init() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let built = Mutex<MailOrderStubAgent?>(nil)
        self.agentEnd = agentEnd
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            let stub = MailOrderStubAgent(connection: connection, messageIds: [])
            built.withLock { $0 = stub }
            return stub
        }
        let model = ConnectionModel(coalescingCadence: .zero)
        self.model = model
        _ = await model.connect(over: clientEnd)
        do {
            _ = try await model.initialize(makeInitializeRequest())
            session = try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: "/")))
            agent = try #require(built.withLock { $0 })
        } catch {
            await model.disconnect()
            throw error
        }
    }

    /// Waits until the session holds a pending request.
    ///
    /// The failure event is the close of the session, or the end of the call
    /// of the agent.
    ///
    /// - Parameters:
    ///   - call: The task of the call of the agent that sends the request.
    ///   - isPending: Tells whether the session holds the request.
    ///   - sourceLocation: The call site, for the issue of a failed wait.
    /// - Throws: ``WaitEndedOnFailure`` when a failure event came first.
    func waitUntilPending<Success: Sendable>(
        _ call: Task<Success, any Error>,
        _ isPending: @escaping @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let callEnd = TaskEnd(of: call)
        try await waitUntil(
            isPending,
            orFailWhen: { [session] in session.isClosed || callEnd.hasEnded },
            sourceLocation: sourceLocation
        )
    }

    /// Waits until the session holds a record of a withdrawn request. The
    /// close of the session is the failure event.
    ///
    /// - Parameter sourceLocation: The call site, for the issue of a failed
    ///   wait.
    /// - Throws: ``WaitEndedOnFailure`` when the session closed first.
    func waitForRecord(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil(
            { [session] in !session.withdrawnRequests.isEmpty },
            orFailWhen: { [session] in session.isClosed },
            sourceLocation: sourceLocation
        )
    }
}

/// The withdrawal tests, in one suite so that `swift test --filter
/// WithdrawnRequestTests` selects them.
@MainActor
@Suite
struct WithdrawnRequestTests {
    /// The session-scoped form elicitation of the test session.
    private let request = ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))

    @Test func anElicitationThatTheAgentWithdrawsGivesARecordWithTheReason() async throws {
        let connected = try await WithdrawalSession()
        defer { await connected.model.disconnect() }
        let cancellation = OutboundCancellation()
        let call = connected.agent.startElicitation(request, cancellation: cancellation)
        try await connected.waitUntilPending(call) { !connected.session.pendingRequests.isEmpty }
        let pending = try #require(connected.session.pendingRequests.first)

        cancellation.setMeta(.object([CancelRequestNotification.reasonMetaKey: .string(runCancelledReason)]))
        call.cancel()
        try await connected.waitForRecord()

        #expect(connected.session.pendingRequests.isEmpty)
        let record = try #require(connected.session.withdrawnRequests.first)
        #expect(record.id == pending.id)
        #expect(record.request == pending)
        #expect(record.reason == runCancelledReason)
        await #expect(throws: (any Error).self) { try await call.value }
    }

    @Test func aPermissionThatTheAgentWithdrawsWithNoMetaGivesARecordWithNoReason() async throws {
        let connected = try await WithdrawalSession()
        defer { await connected.model.disconnect() }
        let call = connected.agent.startPermission(SessionModelFixtures.permissionRequest())
        try await connected.waitUntilPending(call) { !connected.session.pendingPermissions.isEmpty }
        let pending = try #require(connected.session.pendingRequests.first)

        call.cancel()
        try await connected.waitForRecord()

        #expect(connected.session.pendingPermissions.isEmpty)
        #expect(connected.session.withdrawnRequests.map(\.id) == [pending.id])
        #expect(connected.session.withdrawnRequests.first?.reason == nil)
        await #expect(throws: (any Error).self) { try await call.value }
    }

    /// The permission handler runs in a child task of the request task, and
    /// the reason of the `$/cancel_request` reaches it too.
    @Test func aPermissionThatTheAgentWithdrawsGivesARecordWithTheReason() async throws {
        let connected = try await WithdrawalSession()
        defer { await connected.model.disconnect() }
        let cancellation = OutboundCancellation()
        let call = connected.agent.startPermission(SessionModelFixtures.permissionRequest(), cancellation: cancellation)
        try await connected.waitUntilPending(call) { !connected.session.pendingPermissions.isEmpty }
        let pending = try #require(connected.session.pendingRequests.first)

        cancellation.setMeta(.object([CancelRequestNotification.reasonMetaKey: .string(runCancelledReason)]))
        call.cancel()
        try await connected.waitForRecord()

        #expect(connected.session.pendingPermissions.isEmpty)
        let record = try #require(connected.session.withdrawnRequests.first)
        #expect(record.id == pending.id)
        #expect(record.request == pending)
        #expect(record.reason == runCancelledReason)
        await #expect(throws: (any Error).self) { try await call.value }
    }

    @Test func dismissWithdrawnRemovesTheRecord() async throws {
        let connected = try await WithdrawalSession()
        defer { await connected.model.disconnect() }
        let call = connected.agent.startElicitation(request)
        try await connected.waitUntilPending(call) { !connected.session.pendingRequests.isEmpty }
        call.cancel()
        try await connected.waitForRecord()
        let record = try #require(connected.session.withdrawnRequests.first)

        connected.session.dismissWithdrawn(record.id)

        #expect(connected.session.withdrawnRequests.isEmpty)
        _ = try? await call.value
    }

    @Test func anAnswerOfTheUserGivesNoRecord() async throws {
        let connected = try await WithdrawalSession()
        defer { await connected.model.disconnect() }
        let call = connected.agent.startElicitation(request)
        try await connected.waitUntilPending(call) { !connected.session.pendingElicitations.isEmpty }
        let pending = try #require(connected.session.pendingElicitations.first)

        connected.session.declineElicitation(pending.id)

        #expect(try await call.value == ElicitationResponseWire.declineResponse)
        #expect(connected.session.withdrawnRequests.isEmpty)
    }

    /// The close is the behavior under test, so the body closes the
    /// connection itself. The `defer` closes it only when the body throws
    /// before the close.
    @Test func theCloseEmptiesTheList() async throws {
        let connected = try await WithdrawalSession()
        defer { await connected.model.disconnect() }
        let call = connected.agent.startElicitation(request)
        try await connected.waitUntilPending(call) { !connected.session.pendingRequests.isEmpty }
        call.cancel()
        try await connected.waitForRecord()

        await connected.model.disconnect()

        #expect(connected.session.withdrawnRequests.isEmpty)
        _ = try? await call.value
    }

    /// The close of the transport cancels the task of the pending request
    /// before the model learns of the close. The task must make no record,
    /// at any time: the test watches the list from before the close until
    /// the model is disconnected.
    @Test func aTransportCloseWithAPendingRequestGivesNoRecord() async throws {
        let connected = try await WithdrawalSession()
        defer { await connected.model.disconnect() }
        let call = connected.agent.startElicitation(request)
        try await connected.waitUntilPending(call) { !connected.session.pendingRequests.isEmpty }
        let changed = Mutex(false)
        withObservationTracking {
            _ = connected.session.withdrawnRequests
        } onChange: {
            changed.withLock { $0 = true }
        }

        connected.agentEnd.close()
        // The state `.disconnected` comes only after the handler of the
        // elicitation ended, with its record step. The read loop of the
        // connection shuts down, then it waits for each task of an inbound
        // request, and only then it gives the close reason. The model sets
        // `.disconnected` only after that reason. Thus a record that the
        // close makes is in the list before the wait ends. A failed read is
        // the failure event: it closes the connection with a different
        // state.
        try await waitUntil(
            { connected.model.state == .disconnected },
            orFailWhen: {
                guard case .failed = connected.model.state else { return false }
                return true
            }
        )

        #expect(!changed.withLock { $0 }, "The close made a record of a withdrawn request.")
        #expect(connected.session.withdrawnRequests.isEmpty)
        call.cancel()
        _ = try? await call.value
    }
}
