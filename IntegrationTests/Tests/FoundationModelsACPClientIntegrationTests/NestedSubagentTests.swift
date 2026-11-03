import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Observation
import Testing

// The integration test of the sub-agent model against the nested scenario of
// `acp-test-agent` of the wire package (`--scenario nested-subagents`). The
// agent plays a fixed script when the client resumes the session "root": the
// history, a `subagent_update` for each running child, the current root
// state, the response, the current snapshots, an elicitation for the child
// that restored, and the finish. The test uses the public API only. No wait
// reads a clock or polls: each wait tracks the observable value that it reads.

/// The prefix of the name of the temporary directory of the test.
private let temporaryDirectoryPrefix = "acp-client-nested-integration"

/// The client name that the test gives in `initialize`.
private let clientName = "acp-client-nested-integration-test"

/// The ids of the scenario.
private let rootId = SessionId(rawValue: "root")
private let childId = SessionId(rawValue: "child-1")
private let grandchildId = SessionId(rawValue: "grandchild-1")
private let failedChildId = SessionId(rawValue: "child-2")
private let failedGrandchildId = SessionId(rawValue: "grandchild-2")

/// Waits until a condition on observable state is true, or until its failure
/// event is true. It reads no clock.
///
/// - Parameters:
///   - condition: The condition to wait for.
///   - failure: The failure event, for example the close of the connection.
/// - Throws: An error when the failure event came first.
@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    orFailWhen failure: @escaping @MainActor () -> Bool
) async throws {
    struct EndedOnFailure: Error {}
    let ended: @MainActor () -> Bool = { condition() || failure() }
    while !ended() {
        await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = ended()
            } onChange: {
                changed.resume()
            }
        }
    }
    guard condition() else { throw EndedOnFailure() }
}

/// Finds a session in the tree under a root session.
///
/// - Parameters:
///   - sessionId: The id to find.
///   - root: The session whose tree to search.
/// - Returns: The model, or `nil` when no model under the root has that id.
@MainActor
private func findSession(_ sessionId: SessionId, under root: SessionModel) -> SessionModel? {
    for child in root.children {
        if child.id == sessionId { return child }
        if let found = findSession(sessionId, under: child) { return found }
    }
    return nil
}

struct NestedSubagentTests {
    /// The model resumes the session of the nested scenario, and follows the
    /// tree: the running child confirms from its current snapshot, the child
    /// that failed to restore shows unknown with its reason, the elicitation
    /// of the child stays with the child, and the child leaves the tree at the
    /// final tool call update.
    @Test
    @MainActor
    func aResumeBuildsTheNestedTreeAndFollowsItToTheFinish() async throws {
        let root = try IntegrationTemporaryDirectory.make(prefix: temporaryDirectoryPrefix)
        let agentProcess = try await LiveAgentServerBuild(rootDirectory: root)
            .startExecutable(LiveAgentServerBuild.acpTestAgent, arguments: ["--scenario", "nested-subagents"])
        defer { agentProcess.shutdown() }
        let model = ConnectionModel(coalescingCadence: .zero)
        _ = await model.connect(over: agentProcess.transport)
        defer { await model.disconnect() }
        _ = try await model.initialize(.integrationTest(clientName: clientName))

        let session = try await model.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: root.path),
                sessionId: rootId,
                replayFrom: .start(ReplayFromStart())
            )
        )
        let closed: @MainActor () -> Bool = { session.isClosed }

        // The root snapshot before the response is current, and the response
        // ended the replay of every model.
        #expect(session.agentState != nil)
        #expect(!session.isReplaying)
        #expect(session.children.map(\.id) == [childId, failedChildId])

        // The child that restored gets its current snapshot after the
        // response, and confirms. Its grandchild is in the tree.
        let child = try #require(findSession(childId, under: session))
        try await waitUntil({ child.isWorkStateConfirmed }, orFailWhen: closed)
        #expect(child.restoreFailure == nil)
        let grandchild = try await waitForSession(grandchildId, under: session)
        #expect(grandchild.parent === child)

        // The child that failed to restore, and its grandchild, are in the
        // tree as unknown with a reason, and allow no prompt and no cancel.
        let failedChild = try #require(findSession(failedChildId, under: session))
        try await waitUntil({ failedChild.restoreFailure != nil }, orFailWhen: closed)
        #expect(failedChild.workState == .unknown)
        #expect(failedChild.capabilities == nil)
        let failedGrandchild = try await waitForSession(failedGrandchildId, under: session)
        try await waitUntil({ failedGrandchild.restoreFailure != nil }, orFailWhen: closed)
        #expect(failedGrandchild.workState == .unknown)
        #expect(!failedChild.needsAttention)

        // The elicitation arrives under the child that restored only, after
        // its announcement. The agent waits for the answer.
        try await waitUntil({ !child.pendingElicitations.isEmpty }, orFailWhen: closed)
        #expect(session.pendingElicitations.isEmpty)
        let elicitation = try #require(child.pendingElicitations.first)
        #expect(child.needsAttention)
        #expect(session.needsAttention)
        child.declineElicitation(elicitation.id)

        // The final tool call update of the agents call removes the child.
        try await waitUntil({ child.isClosed }, orFailWhen: closed)
        #expect(session.children.map(\.id) == [failedChildId])

        await model.disconnect()
        let agentExit = try await agentProcess.waitForExit()
        #expect(agentExit != .notCollected, "the teardown did not reap the agent process")
        try FileManager.default.removeItem(at: root)
    }

    /// Waits until the model made a session of the tree, and gives it.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session.
    ///   - root: The session whose tree to search. Its close is the failure
    ///     event.
    /// - Returns: The model.
    @MainActor
    private func waitForSession(_ sessionId: SessionId, under root: SessionModel) async throws -> SessionModel {
        try await waitUntil({ findSession(sessionId, under: root) != nil }, orFailWhen: { root.isClosed })
        return try #require(findSession(sessionId, under: root))
    }
}
