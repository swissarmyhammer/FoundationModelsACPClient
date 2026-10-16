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
        model = ConnectionModel(coalescingCadence: .zero)
        _ = await model.connect(over: clientEnd)
        _ = try await model.initialize(makeInitializeRequest())
        session = try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: "/")))
        agent = try #require(built.withLock { $0 })
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
        let cancellation = OutboundCancellation()
        let call = connected.agent.startElicitation(request, cancellation: cancellation)
        await waitFor { !connected.session.pendingRequests.isEmpty }
        let pending = try #require(connected.session.pendingRequests.first)

        cancellation.setMeta(.object([CancelRequestNotification.reasonMetaKey: .string(runCancelledReason)]))
        call.cancel()
        await waitFor { !connected.session.withdrawnRequests.isEmpty }

        #expect(connected.session.pendingRequests.isEmpty)
        let record = try #require(connected.session.withdrawnRequests.first)
        #expect(record.id == pending.id)
        #expect(record.request == pending)
        #expect(record.reason == runCancelledReason)
        await #expect(throws: (any Error).self) { try await call.value }
        await connected.model.disconnect()
    }

    @Test func aPermissionThatTheAgentWithdrawsWithNoMetaGivesARecordWithNoReason() async throws {
        let connected = try await WithdrawalSession()
        let call = connected.agent.startPermission(SessionModelFixtures.permissionRequest())
        await waitFor { !connected.session.pendingPermissions.isEmpty }
        let pending = try #require(connected.session.pendingRequests.first)

        call.cancel()
        await waitFor { !connected.session.withdrawnRequests.isEmpty }

        #expect(connected.session.pendingPermissions.isEmpty)
        #expect(connected.session.withdrawnRequests.map(\.id) == [pending.id])
        #expect(connected.session.withdrawnRequests.first?.reason == nil)
        await #expect(throws: (any Error).self) { try await call.value }
        await connected.model.disconnect()
    }

    /// The permission handler runs in a child task of the request task, and
    /// the reason of the `$/cancel_request` reaches it too.
    @Test func aPermissionThatTheAgentWithdrawsGivesARecordWithTheReason() async throws {
        let connected = try await WithdrawalSession()
        let cancellation = OutboundCancellation()
        let call = connected.agent.startPermission(SessionModelFixtures.permissionRequest(), cancellation: cancellation)
        await waitFor { !connected.session.pendingPermissions.isEmpty }
        let pending = try #require(connected.session.pendingRequests.first)

        cancellation.setMeta(.object([CancelRequestNotification.reasonMetaKey: .string(runCancelledReason)]))
        call.cancel()
        await waitFor { !connected.session.withdrawnRequests.isEmpty }

        #expect(connected.session.pendingPermissions.isEmpty)
        let record = try #require(connected.session.withdrawnRequests.first)
        #expect(record.id == pending.id)
        #expect(record.request == pending)
        #expect(record.reason == runCancelledReason)
        await #expect(throws: (any Error).self) { try await call.value }
        await connected.model.disconnect()
    }

    @Test func dismissWithdrawnRemovesTheRecord() async throws {
        let connected = try await WithdrawalSession()
        let call = connected.agent.startElicitation(request)
        await waitFor { !connected.session.pendingRequests.isEmpty }
        call.cancel()
        await waitFor { !connected.session.withdrawnRequests.isEmpty }
        let record = try #require(connected.session.withdrawnRequests.first)

        connected.session.dismissWithdrawn(record.id)

        #expect(connected.session.withdrawnRequests.isEmpty)
        _ = try? await call.value
        await connected.model.disconnect()
    }

    @Test func anAnswerOfTheUserGivesNoRecord() async throws {
        let connected = try await WithdrawalSession()
        let call = connected.agent.startElicitation(request)
        await waitFor { !connected.session.pendingElicitations.isEmpty }
        let pending = try #require(connected.session.pendingElicitations.first)

        connected.session.declineElicitation(pending.id)

        #expect(try await call.value == ElicitationResponseWire.declineResponse)
        #expect(connected.session.withdrawnRequests.isEmpty)
        await connected.model.disconnect()
    }

    @Test func theCloseEmptiesTheList() async throws {
        let connected = try await WithdrawalSession()
        let call = connected.agent.startElicitation(request)
        await waitFor { !connected.session.pendingRequests.isEmpty }
        call.cancel()
        await waitFor { !connected.session.withdrawnRequests.isEmpty }

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
        let call = connected.agent.startElicitation(request)
        await waitFor { !connected.session.pendingRequests.isEmpty }
        let changed = Mutex(false)
        withObservationTracking {
            _ = connected.session.withdrawnRequests
        } onChange: {
            changed.withLock { $0 = true }
        }

        connected.agentEnd.close()
        await waitFor { connected.model.state == .disconnected }

        #expect(!changed.withLock { $0 }, "The close made a record of a withdrawn request.")
        #expect(connected.session.withdrawnRequests.isEmpty)
        call.cancel()
        _ = try? await call.value
    }
}
