import FoundationModelsACP
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
