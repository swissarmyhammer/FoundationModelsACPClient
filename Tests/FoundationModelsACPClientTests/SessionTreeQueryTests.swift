import FoundationModelsACP
import Observation
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// The tests of the tree queries that a view needs: `root`, `path`,
// `session(withId:)`, `nearestOpenAncestor`, `status`, `canPrompt`,
// `canCancel`, `ownNeedsAttention`, `firstWaitingSession`,
// `branchPendingRequestCount`, the entry fields `isConfirmed` and
// `restoreFailure`, `replayEndCount`, and the observable `childSession`.

/// The grandchild of the tests.
private let queryGrandchild = SessionId(rawValue: "query-grandchild")

/// Makes a root with a child and a grandchild.
///
/// - Returns: The connection, the child, and the grandchild.
@MainActor
private func connectChain() async throws -> (ResumeConnection, SessionModel, SessionModel) {
    let connected = try await ResumeConnection.make()
    let child = try await connected.announce(try snapshot(firstChild, state: .value(.running(RunningStateUpdate()))), child: firstChild)
    try await connected.agent.send(try snapshot(queryGrandchild), to: firstChild)
    let grandchild = try await waitForChild(queryGrandchild, under: connected.root)
    return (connected, child, grandchild)
}

@MainActor
struct SessionTreeQueryTests {
    @Test func theRootAndThePathOfAGrandchild() async throws {
        let (connected, child, grandchild) = try await connectChain()
        defer { await connected.model.disconnect() }

        #expect(grandchild.root === connected.root)
        #expect(connected.root.root === connected.root)
        #expect(grandchild.path.map(\.id) == [testSession, firstChild, queryGrandchild])
        #expect(child.path.last === child)
    }

    @Test func aSessionIsFoundByIdInItsOwnTree() async throws {
        let (connected, child, grandchild) = try await connectChain()
        defer { await connected.model.disconnect() }

        #expect(connected.root.session(withId: queryGrandchild) === grandchild)
        #expect(child.session(withId: firstChild) === child)
        #expect(child.session(withId: testSession) == nil)
    }

    @Test func theNearestOpenAncestorSkipsAClosedAncestor() async throws {
        let (connected, child, grandchild) = try await connectChain()
        defer { await connected.model.disconnect() }

        #expect(grandchild.nearestOpenAncestor === child)
        child.removeFromParent()
        #expect(grandchild.nearestOpenAncestor === connected.root)
        #expect(connected.root.nearestOpenAncestor == nil)
    }

    @Test func theStatusTellsWhyAStateIsUnknown() async throws {
        let (connected, child, grandchild) = try await connectChain()
        defer { await connected.model.disconnect() }

        #expect(child.status == .running)
        // The grandchild has a snapshot with no state: it is confirmed, and its state is unknown.
        #expect(grandchild.status == .unknown)
        child.isWorkStateConfirmed = false
        #expect(child.status == .unconfirmed)
        grandchild.restoreFailure = "missing tool"
        #expect(grandchild.status == .restoreFailed(reason: "missing tool"))
    }

    @Test func theControlsOfAChildFollowItsCapabilities() async throws {
        let (connected, child, _) = try await connectChain()
        defer { await connected.model.disconnect() }

        #expect(connected.root.canPrompt)
        #expect(connected.root.canCancel)
        #expect(!child.canPrompt)
        #expect(!child.canCancel)
        child.capabilities = cancelCapabilities
        #expect(child.canCancel)
        child.isWorkStateConfirmed = false
        #expect(!child.canCancel)
    }

    @Test func aSessionThatWaitsItselfIsNamedByTheFirstWaitingSession() async throws {
        let (connected, child, grandchild) = try await connectChain()
        defer { await connected.model.disconnect() }
        let request = RequestPermissionRequest(
            options: [PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))],
            sessionId: queryGrandchild,
            title: "Run"
        )

        let task = connected.agent.startPermission(request)
        defer { task.cancel() }
        try await waitForObservation { !grandchild.pendingPermissions.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(grandchild.ownNeedsAttention)
        #expect(!child.ownNeedsAttention)
        #expect(child.needsAttention)
        #expect(connected.root.firstWaitingSession === grandchild)
        #expect(connected.root.branchPendingRequestCount == 1)
        #expect(child.branchPendingRequestCount == 1)
        #expect(grandchild.pathEntry.isConfirmed)
    }

    @Test func anEntryCarriesTheConfirmationAndTheRestoreFailure() async throws {
        let (connected, child, _) = try await connectChain()
        defer { await connected.model.disconnect() }
        child.isWorkStateConfirmed = false
        child.restoreFailure = "gone"

        let entry = child.pathEntry

        #expect(!entry.isConfirmed)
        #expect(entry.restoreFailure == "gone")
    }

    @Test func theEndOfAResumeCountsInReplayEndCount() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let before = connected.root.replayEndCount

        _ = try await connected.resume(replayFrom: nil)

        #expect(connected.root.replayEndCount == before + 1)
    }

    @Test func aToolCallLinkToAChildIsObservable() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(try snapshot(firstChild, toolCall: agentsCall), child: firstChild)
        try await connected.agent.send(toolCallStatus(id: agentsCall.rawValue, .inProgress))
        try await waitForObservation { connected.root.transcript.first?.toolCall != nil } orFailWhen: {
            connected.root.isClosed
        }
        let call = try #require(connected.root.transcript.first?.toolCall)
        let fired = Mutex(false)
        withObservationTracking {
            _ = call.childSession
        } onChange: {
            fired.withLock { $0 = true }
        }

        let link = try SAH.AgentRun(sessionId: firstChild).inject(into: nil)
        try await connected.agent.send(
            .toolCallUpdate(ToolCallUpdate(toolCallId: agentsCall, meta: .value(link)))
        )
        try await waitForObservation { call.childSession === child } orFailWhen: { connected.root.isClosed }

        #expect(fired.withLock { $0 })
    }
}
