import FoundationModelsACP
import Observation
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// The tests of a child session that failed to restore. The agent announces
// such a child, and does not hide it: its `subagent_update` has the state
// `unknown`, no capabilities, and the short reason in `_meta.sah`. The root
// still resumes. The child is in the tree as unknown, with the reason in
// `restoreFailure`, and the client sends it no prompt and no cancel.

/// The reason that the agent gives for the failed child.
private let missingTool = "missing tool: search"

/// The reason that the agent gives for a descendant of a failed child.
private let ancestorFailed = "an ancestor was not restored"

/// The child of the failed child.
private let nestedChild = SessionId(rawValue: "child-1-nested")

/// Makes the `subagent_update` of a child that failed to restore.
///
/// - Parameters:
///   - child: The id of the child.
///   - reason: The short reason.
/// - Returns: The update, with the state `unknown`, no capabilities, and the
///   reason in `_meta.sah.restoreFailure`.
private func failedSnapshot(_ child: SessionId, reason: String) throws -> SessionUpdate {
    try snapshot(
        child,
        state: .value(.unknown("unknown", .object([:]))),
        capabilities: .cleared,
        meta: .value(try SAH.RestoreFailure(reason: reason).inject(into: nil))
    )
}

/// The restore-failure tests, in one suite so that `swift test --filter
/// SubagentRestoreFailureTests` selects them.
@MainActor
struct SubagentRestoreFailureTests {
    /// Resumes a session whose replay announces a failed child.
    ///
    /// - Returns: The connection, and the failed child.
    private func resumeWithFailedChild() async throws -> (ResumeConnection, SessionModel) {
        let connected = try await ResumeConnection.make()
        connected.agent.setReplay { connection in
            try await connection.sessionUpdate(
                UpdateSessionNotification(sessionId: testSession, update: try failedSnapshot(firstChild, reason: missingTool))
            )
        }
        _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)
        return (connected, try #require(childModel(firstChild, under: connected.root)))
    }

    @Test func aChildThatFailedToRestoreIsUnknownWithItsReason() async throws {
        let (connected, child) = try await resumeWithFailedChild()
        defer { await connected.model.disconnect() }

        #expect(child.restoreFailure == missingTool)
        #expect(child.workState == .unknown)
        #expect(child.capabilities == nil)
    }

    @Test func aHealthyChildHasNoRestoreFailure() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }

        let child = try await connected.announce(try snapshot(firstChild), child: firstChild)

        #expect(child.restoreFailure == nil)
    }

    @Test func aFailedChildAllowsNeitherCancelNorPrompt() async throws {
        let (connected, child) = try await resumeWithFailedChild()
        defer { await connected.model.disconnect() }

        await #expect(throws: SubagentSessionError.notPermitted(operation: ClientRequestSpan.Method.cancelSession)) {
            try await child.cancel()
        }
        await #expect(throws: SubagentSessionError.notPermitted(operation: ClientRequestSpan.Method.prompt)) {
            _ = try await child.prompt([textBlock("hi")])
        }
    }

    @Test func aFailedChildIsInChildrenDescendantsAndAncestors() async throws {
        let (connected, child) = try await resumeWithFailedChild()
        defer { await connected.model.disconnect() }
        try await connected.agent.send(try failedSnapshot(nestedChild, reason: ancestorFailed), to: firstChild)
        let nested = try await waitForChild(nestedChild, under: connected.root)

        #expect(connected.root.children.map(\.id) == [firstChild])
        #expect(connected.root.descendants.map(\.sessionId) == [firstChild, nestedChild])
        #expect(nested.ancestors.map(\.sessionId) == [testSession, firstChild])
        #expect(child.restoreFailure == missingTool)
    }

    @Test func aFailedChildKeepsItsIdOnASecondResume() async throws {
        let (connected, _) = try await resumeWithFailedChild()
        defer { await connected.model.disconnect() }

        _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)

        let again = try #require(childModel(firstChild, under: connected.root))
        #expect(again.id == firstChild)
        #expect(again.restoreFailure == missingTool)
        #expect(connected.root.children.count == 1)
    }

    @Test func aResumeThatKeepsTheChildrenStartsWithNoStaleReason() async throws {
        let (connected, child) = try await resumeWithFailedChild()
        defer { await connected.model.disconnect() }
        connected.agent.setReplay { _ in }

        _ = try await connected.resume(replayFrom: nil)

        #expect(connected.root.children.first === child)
        #expect(child.restoreFailure == nil)
    }

    @Test func aLaterCurrentSnapshotWithAStateClearsTheRestoreFailure() async throws {
        let (connected, child) = try await resumeWithFailedChild()
        defer { await connected.model.disconnect() }

        try await connected.agent.send(
            try snapshot(firstChild, state: .value(.running(RunningStateUpdate())), capabilities: .value(cancelCapabilities))
        )
        try await waitForObservation { child.restoreFailure == nil } orFailWhen: { connected.root.isClosed }

        #expect(child.workState == .running)
        #expect(child.capabilities == cancelCapabilities)
    }

    @Test func aDescendantOfAFailedChildIsAnnouncedAsUnknownWithItsOwnReason() async throws {
        let (connected, _) = try await resumeWithFailedChild()
        defer { await connected.model.disconnect() }

        try await connected.agent.send(try failedSnapshot(nestedChild, reason: ancestorFailed), to: firstChild)
        let nested = try await waitForChild(nestedChild, under: connected.root)

        #expect(nested.restoreFailure == ancestorFailed)
        #expect(nested.workState == .unknown)
    }

    @Test func aFailedChildDoesNotNeedAttention() async throws {
        let (connected, child) = try await resumeWithFailedChild()
        defer { await connected.model.disconnect() }

        #expect(!child.needsAttention)
        #expect(!connected.root.needsAttention)
    }

    @Test func aChangeOfTheRestoreFailureFiresItsObservation() async throws {
        let (connected, child) = try await resumeWithFailedChild()
        defer { await connected.model.disconnect() }
        let fired = Mutex(false)
        withObservationTracking {
            _ = child.restoreFailure
        } onChange: {
            fired.withLock { $0 = true }
        }

        try await connected.agent.send(
            try snapshot(firstChild, state: .value(.running(RunningStateUpdate())))
        )
        try await waitForObservation { child.restoreFailure == nil } orFailWhen: { connected.root.isClosed }

        #expect(fired.withLock { $0 })
    }
}
