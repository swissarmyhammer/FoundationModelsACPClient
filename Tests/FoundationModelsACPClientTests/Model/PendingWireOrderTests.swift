import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the order of the pending requests (bug ^s39vtvg, from
// AgentViewKit deck card 36). The deck is FIFO by arrival, and the arrival
// order is the wire order. The connection handles each request of the agent in
// its own task, so the requests can get to a model in a different order than
// the wire order. The model puts each request at the position of its wire
// arrival number.
//
// The first test fixes the order: it gives the arrival numbers, and starts the
// requests in an order that is not the order of the numbers. The old code
// fails it each time. The second test is the check over the real wire. The
// fixed-order test of `ConnectionModel` is in `ConnectionModelElicitationTests`,
// because a request-scoped elicitation needs the login harness of that file.

/// The label of one pending request: the title of a permission request, or
/// "elicitation".
///
/// - Parameter request: The pending request.
/// - Returns: The label.
private func label(of request: PendingRequest) -> String {
    switch request {
    case .permission(let permission): permission.request.title
    case .elicitation: "elicitation"
    }
}

/// The session-scoped form elicitation of the test session.
private let sessionElicitation = ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))

/// The wire-order tests, in one suite so that `swift test --filter
/// PendingWireOrderTests` selects them.
@MainActor
@Suite
struct PendingWireOrderTests {
    /// A request with a smaller arrival number goes in front of the requests
    /// that got to the model before it, in both typed lists and in
    /// `pendingRequests`. The old code appends each request, and gives
    /// "second", "elicitation", "first".
    @Test func aRequestWithASmallerArrivalGoesInFrontOfTheRequestsThatCameFirst() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())

        // The model has no connection. Each wait ends also on the end of the
        // task that must add the request: a task that ended did not add it.
        let second = Task {
            await model.awaitPermissionDecision(for: SessionModelFixtures.permissionRequest(title: "second"), arrival: 2)
        }
        let secondEnd = TaskEnd(of: second)
        try await waitUntil { model.pendingRequests.count == 1 } orFailWhen: { secondEnd.hasEnded }
        let elicitation = Task { await model.awaitElicitation(sessionElicitation, arrival: 3) }
        let elicitationEnd = TaskEnd(of: elicitation)
        try await waitUntil { model.pendingRequests.count == 2 } orFailWhen: { elicitationEnd.hasEnded }
        let first = Task {
            await model.awaitPermissionDecision(for: SessionModelFixtures.permissionRequest(title: "first"), arrival: 1)
        }
        let firstEnd = TaskEnd(of: first)
        try await waitUntil { model.pendingRequests.count == 3 } orFailWhen: { firstEnd.hasEnded }

        #expect(model.pendingRequests.map(label(of:)) == ["first", "second", "elicitation"])
        #expect(model.pendingPermissions.map(\.request.title) == ["first", "second"])
        #expect(model.frontRequest.map(label(of:)) == "first")

        model.cancelAllPending()
        _ = await (first.value, second.value, elicitation.value)
    }

    /// A request with no wire number and a request with a wire number get
    /// numbers of one space. A request with no wire number goes after each
    /// wire request that came before it, so a later wire request goes after
    /// it. The old code takes a process-wide number for a request with no wire
    /// number, and the wire numbers of a connection start at 0, so it puts
    /// "wire" in front of "first" or of "second".
    @Test func aRequestWithNoWireNumberAndAWireRequestKeepTheirArrivalOrder() async throws {
        let model = SessionModel(sessionId: testSession, requestSender: FakeSessionRequestSender())

        // The model has no connection. Each wait ends also on the end of the
        // task that must add the request: a task that ended did not add it.
        let first = Task { await model.awaitPermissionDecision(for: SessionModelFixtures.permissionRequest(title: "first")) }
        let firstEnd = TaskEnd(of: first)
        try await waitUntil { model.pendingRequests.count == 1 } orFailWhen: { firstEnd.hasEnded }
        let second = Task { await model.awaitPermissionDecision(for: SessionModelFixtures.permissionRequest(title: "second")) }
        let secondEnd = TaskEnd(of: second)
        try await waitUntil { model.pendingRequests.count == 2 } orFailWhen: { secondEnd.hasEnded }
        let wire = Task {
            await model.awaitPermissionDecision(for: SessionModelFixtures.permissionRequest(title: "wire"), arrival: 0)
        }
        let wireEnd = TaskEnd(of: wire)
        try await waitUntil { model.pendingRequests.count == 3 } orFailWhen: { wireEnd.hasEnded }

        #expect(model.pendingRequests.map(label(of:)) == ["first", "second", "wire"])

        model.cancelAllPending()
        _ = await (first.value, second.value, wire.value)
    }

    /// Two permission requests and one elicitation in one transport write are
    /// pending on the session model in wire order.
    @Test func requestsInOneWriteArePendingInWireOrder() async throws {
        let wireOrder = ["first", "elicitation", "second"]
        let burst = try RawBurstAgent.request(
            id: "p-1",
            method: ClientRequestSpan.Method.requestPermission,
            params: SessionModelFixtures.permissionRequest(title: "first")
        )
            + RawBurstAgent.request(id: "e-1", method: ClientRequestSpan.Method.createElicitation, params: sessionElicitation)
            + RawBurstAgent.request(
                id: "p-2",
                method: ClientRequestSpan.Method.requestPermission,
                params: SessionModelFixtures.permissionRequest(title: "second")
            )
        let (model, session, agentRun) = try await RawBurstAgent.connect(burst: burst)
        defer {
            await model.disconnect()
            agentRun.cancel()
        }

        try await waitUntil { session.pendingRequests.count == wireOrder.count } orFailWhen: { session.isClosed }

        #expect(session.pendingRequests.map(label(of:)) == wireOrder)
        #expect(session.pendingPermissions.map(\.request.title) == ["first", "second"])
    }
}
