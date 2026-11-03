import FoundationModelsACP
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// The tests of the one consumer of the ordered event stream. The agent sends
// the replay of a chain of three sessions (a root, a child and a grandchild,
// each on its own session id), then the resume response, then at once after
// the response a permission request for the grandchild. The consumer applies
// each event in wire order, so the grandchild model exists when the request
// arrives, and the response ends the replay of every model at one position.

/// The grandchild of the chain.
private let nestedGrandchild = SessionId(rawValue: "grandchild-1")

/// The permission request for the grandchild.
private let grandchildRequest = RequestPermissionRequest(
    options: [PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))],
    sessionId: nestedGrandchild,
    title: "Run"
)

/// The ordered-consumer tests, in one suite so that `swift test --filter
/// OrderedEventConsumerTests` selects them.
@MainActor
struct OrderedEventConsumerTests {
    /// Connects a model whose replay sends the history of a chain of three
    /// sessions, and whose answer is followed by a permission request for the
    /// grandchild.
    ///
    /// - Returns: The connection.
    private func resumeWithChain() async throws -> ResumeConnection {
        let connected = try await ResumeConnection.make()
        let agent = connected.agent
        agent.setReplay { connection in
            func send(_ update: SessionUpdate, to id: SessionId) async throws {
                try await connection.sessionUpdate(UpdateSessionNotification(sessionId: id, update: update))
            }
            try await send(try snapshot(firstChild, state: .value(.running(RunningStateUpdate()))), to: testSession)
            try await send(agentChunk(text: "child history", message: "child-m"), to: firstChild)
            try await send(try snapshot(nestedGrandchild, state: .value(.running(RunningStateUpdate()))), to: firstChild)
            try await send(agentChunk(text: "grandchild history", message: "grandchild-m"), to: nestedGrandchild)
        }
        agent.setAfterAnswer { connection in
            // The agent sends the request at once after the response. The
            // call ends when the user answers or the connection closes.
            _ = try? await connection.requestPermission(grandchildRequest)
        }
        _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)
        return connected
    }

    @Test func aRequestForTheGrandchildAfterTheResponseIsPending() async throws {
        let connected = try await resumeWithChain()
        defer { await connected.model.disconnect() }
        let grandchild = try await waitForChild(nestedGrandchild, under: connected.root)

        try await waitForObservation { grandchild.pendingRequestCount == 1 } orFailWhen: { connected.root.isClosed }

        #expect(grandchild.pendingPermissions.first?.request.sessionId == nestedGrandchild)
    }

    @Test func aRequestWaitsForTheEventsThatCameBeforeIt() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let gate = UpdateGate()
        // The consumer stops at the announcement of the grandchild, which is
        // in the stream of the child. The response and the request of the
        // agent reach the client while the consumer waits.
        connected.model.beforeApplyingEvent = { event in
            guard event.sessionId == firstChild, case .update(.subagentUpdate(let update)) = event.event,
                update.sessionId == nestedGrandchild
            else { return }
            await gate.wait()
        }
        connected.agent.setReplay { connection in
            let first = try snapshot(firstChild)
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: first))
            let nested = try snapshot(nestedGrandchild)
            try await connection.sessionUpdate(UpdateSessionNotification(sessionId: firstChild, update: nested))
        }
        let handlerWaits = Mutex(false)
        let requestAnswered = Mutex(false)
        connected.model.didStartWaitingForEvents = {
            handlerWaits.withLock { $0 = true }
            TestChangeSignal.post()
        }
        connected.agent.setAfterAnswer { connection in
            _ = try? await connection.requestPermission(grandchildRequest)
            requestAnswered.withLock { $0 = true }
            TestChangeSignal.post()
        }
        let resume = Task { try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart) }
        // The handler of the request waits for the held consumer. An answer
        // before that wait means that the handler did not wait.
        try await waitUntil { handlerWaits.withLock { $0 } } orFailWhen: { requestAnswered.withLock { $0 } }

        gate.open()
        _ = try await resume.value
        let grandchild = try await waitForChild(nestedGrandchild, under: connected.root)
        try await waitForObservation { grandchild.pendingRequestCount == 1 } orFailWhen: { connected.root.isClosed }

        #expect(grandchild.pendingPermissions.first?.request.sessionId == nestedGrandchild)
    }

    @Test func aCancelledRequestStopsWaitingForEvents() async throws {
        let connected = try await ResumeConnection.make()
        defer { await connected.model.disconnect() }
        let waiting = Mutex(false)
        connected.model.didStartWaitingForEvents = {
            waiting.withLock { $0 = true }
            TestChangeSignal.post()
        }
        // No event has this sequence, so the wait would last for ever.
        let handler = Task { await connected.model.waitUntilApplied(UInt64.max) }
        let end = TaskEnd(of: handler)
        try await waitUntil { waiting.withLock { $0 } } orFailWhen: { end.hasEnded }

        handler.cancel()

        // This wait has no failure event: a handler that ignores the cancel
        // never ends. This is a known limit of rule T1.
        try await waitUntil({ end.hasEnded }, orFailWhen: noFailureEvent)
    }

    @Test func aGrandchildOfTheReplayIsUnconfirmedAfterTheResponse() async throws {
        let connected = try await resumeWithChain()
        defer { await connected.model.disconnect() }
        let grandchild = try await waitForChild(nestedGrandchild, under: connected.root)

        #expect(!grandchild.isWorkStateConfirmed)
        #expect(grandchild.workState == .unknown)
        #expect(!grandchild.isReplaying)
    }

    @Test func theResponseEndsTheReplayOfEveryModel() async throws {
        let connected = try await resumeWithChain()
        defer { await connected.model.disconnect() }
        let child = try await waitForChild(firstChild, under: connected.root)
        let grandchild = try await waitForChild(nestedGrandchild, under: connected.root)

        #expect(!connected.root.isReplaying)
        #expect(!child.isReplaying)
        #expect(!grandchild.isReplaying)
    }
}

// MARK: - The table of events for sessions with no model

extension OrderedEventConsumerTests {
    @Test func theOldestSessionWithNoModelLeavesFirstWhenTheTableIsFull() async throws {
        let limits = SessionUpdateBufferLimits(maximumUpdatesPerSession: 8, maximumSessions: 2)
        let connected = try await ResumeConnection.make(bufferLimits: limits)
        defer { await connected.model.disconnect() }
        let oldest = SessionId(rawValue: "unknown-a")
        let middle = SessionId(rawValue: "unknown-b")
        let newest = SessionId(rawValue: "unknown-c")
        for id in [oldest, middle, newest] {
            try await connected.agent.send(agentChunk(text: "from \(id.rawValue)", message: "m-\(id.rawValue)"), to: id)
        }
        // A later update of the root proves that the earlier updates went by.
        try await connected.agent.send(agentChunk(text: "mark", message: "root-1"))
        try await waitForObservation { !connected.root.transcript.isEmpty } orFailWhen: { connected.root.isClosed }
        connected.agent.setReplay { _ in }

        let kept = try await connected.model.resumeSession(
            ResumeSessionRequest(cwd: AbsolutePath(rawValue: "/"), sessionId: newest, replayFrom: nil)
        )
        let evicted = try await connected.model.resumeSession(
            ResumeSessionRequest(cwd: AbsolutePath(rawValue: "/"), sessionId: oldest, replayFrom: nil)
        )

        #expect(kept.transcript.count == 1)
        #expect(!kept.hasMissedUpdates)
        #expect(evicted.transcript.isEmpty)
        #expect(evicted.hasMissedUpdates)
    }
}
