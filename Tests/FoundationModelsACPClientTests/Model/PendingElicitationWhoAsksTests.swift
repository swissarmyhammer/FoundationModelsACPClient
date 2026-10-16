import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of "who asks": the `agentPath` and `source` members of the `_meta`
// of `elicitation/create`, which `PendingElicitation` exposes. The agent sends
// each member only when it is not empty, and the root agent adds no name for
// itself.
//
// The wire test writes raw JSON frames, so the `_meta` members reach the
// client as the agent writes them. The model keeps the pending elicitations in
// wire order, so the test reads them by position.

/// Gives the params of a session-scoped form elicitation of the test session,
/// with a `_meta` member.
///
/// - Parameter meta: The `_meta` member, or `nil` for no `_meta`.
/// - Returns: The params as a JSON object.
/// - Throws: The error of the encoder.
private func elicitationParams(meta: [String: Any]?) throws -> [String: Any] {
    let request = ElicitationFixtures.formRequest(scope: .session(ElicitationFixtures.sessionScope))
    guard var params = try RawBurstAgent.json(request) as? [String: Any] else { return [:] }
    params["_meta"] = meta
    return params
}

/// Gives one `elicitation/create` frame with a `_meta` member.
///
/// - Parameters:
///   - id: The wire id of the request.
///   - meta: The `_meta` member, or `nil` for no `_meta`.
/// - Returns: The frame.
/// - Throws: The error of the encoder.
private func elicitationFrame(id: String, meta: [String: Any]?) throws -> Data {
    RawBurstAgent.frame([
        "jsonrpc": "2.0", "id": id, "method": ClientRequestSpan.Method.createElicitation,
        "params": try elicitationParams(meta: meta),
    ])
}

/// Decodes a session-scoped form elicitation with a `_meta` member, as the
/// connection decodes it from the wire.
///
/// - Parameter meta: The `_meta` member.
/// - Returns: The pending elicitation.
/// - Throws: The error of the encoder or of the decoder.
private func pendingElicitation(meta: [String: Any]) throws -> PendingElicitation {
    let data = try JSONSerialization.data(withJSONObject: elicitationParams(meta: meta))
    return PendingElicitation(id: UUID(), request: try JSONDecoder().decode(CreateElicitationRequest.self, from: data))
}

/// The "who asks" tests, in one suite so that `swift test --filter
/// PendingElicitationWhoAsksTests` selects them.
@MainActor
@Suite
struct PendingElicitationWhoAsksTests {
    /// An elicitation with both members gives them, and an elicitation with no
    /// `_meta` gives an empty path and no source.
    @Test func anElicitationOverTheWireGivesItsAgentPathAndSource() async throws {
        let burst = try elicitationFrame(id: "e-1", meta: ["agentPath": ["planner", "coder"], "source": "shell"])
            + elicitationFrame(id: "e-2", meta: nil)
        let (model, session, agentRun) = try await RawBurstAgent.connect(burst: burst)
        defer {
            await model.disconnect()
            agentRun.cancel()
        }

        try await waitUntil { session.pendingElicitations.count == 2 } orFailWhen: { session.isClosed }

        let elicitations = session.pendingElicitations
        try #require(elicitations.count == 2)
        #expect(elicitations[0].agentPath == ["planner", "coder"])
        #expect(elicitations[0].source == "shell")
        #expect(elicitations[1].agentPath.isEmpty)
        #expect(elicitations[1].source == nil)
    }

    @Test func aMetaWithOtherMembersOnlyGivesAnEmptyPathAndNoSource() throws {
        let pending = try pendingElicitation(meta: ["traceparent": "00-abc-def-01"])

        #expect(pending.agentPath.isEmpty)
        #expect(pending.source == nil)
    }

    @Test func membersOfTheWrongTypeAreIgnored() throws {
        let pending = try pendingElicitation(meta: ["agentPath": "planner", "source": 7])

        #expect(pending.agentPath.isEmpty)
        #expect(pending.source == nil)
    }

    @Test func aPathWithAValueThatIsNotAStringIsIgnored() throws {
        let pending = try pendingElicitation(meta: ["agentPath": ["planner", 7]])

        #expect(pending.agentPath.isEmpty)
    }

    @Test func anEmptySourceGivesNoSource() throws {
        let pending = try pendingElicitation(meta: ["source": ""])

        #expect(pending.source == nil)
    }
}
