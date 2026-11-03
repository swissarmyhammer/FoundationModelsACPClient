import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Observation
import Synchronization
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


/// A client that records the requests that wait on the user, with the arrival
/// number of each, and declines each one. The wire trace validator reads the
/// requests in the order of the one counter that numbers each frame.
private final class RecordingClient: Client {
    /// The recorded requests: the arrival number and the session.
    private let requests = Mutex<[(arrival: UInt64, sessionId: SessionId)]>([])

    /// The requests of the agent that wait on the user, in arrival order.
    var recordedRequests: [(arrival: UInt64, sessionId: SessionId)] {
        requests.withLock { $0 }
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: .cancelled(CancelledPermissionOutcome()))
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        let arrival = ClientSideConnection.currentRequestArrival ?? 0
        let sessionId: SessionId
        switch params.mode {
        case .form(let form):
            if case .session(let scope) = form.scope { sessionId = scope.sessionId } else { sessionId = rootId }
        case .url(let url):
            if case .session(let scope) = url.scope { sessionId = scope.sessionId } else { sessionId = rootId }
        case .unknown:
            sessionId = rootId
        }
        requests.withLock { $0.append((arrival, sessionId)) }
        return .object(["action": .string("decline")])
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}

    var extensionHandlers: ExtensionHandlers { ExtensionHandlers() }
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

    /// The messages of the nested scenario, as one client reads them from the
    /// wire in order, follow the rules of the wire trace validator.
    @Test
    @MainActor
    func theNestedScenarioTraceFollowsTheWireRules() async throws {
        let root = try IntegrationTemporaryDirectory.make(prefix: temporaryDirectoryPrefix)
        let agentProcess = try await LiveAgentServerBuild(rootDirectory: root)
            .startExecutable(LiveAgentServerBuild.acpTestAgent, arguments: ["--scenario", "nested-subagents"])
        defer { agentProcess.shutdown() }
        let client = RecordingClient()
        let connection = await ClientSideConnection(stream: agentProcess.transport) { _ in client }
        // The subscription starts before the first request, so it holds every
        // event from the start of the connection.
        let all = connection.subscribeToAllSessions()
        let outgoing = connection.subscribeToOutgoingRequests()
        _ = try await connection.initialize(.integrationTest(clientName: clientName))
        var started = outgoing.makeAsyncIterator()
        let resume = Task {
            try await connection.resumeSession(
                ResumeSessionRequest(
                    cwd: AbsolutePath(rawValue: root.path),
                    sessionId: rootId,
                    replayFrom: .start(ReplayFromStart())
                )
            )
        }
        // The id of the resume request, from the outgoing-request events.
        var resumeId: RequestId?
        while let event = await started.next() {
            if case .started(let id, let method) = event, method == "session/resume" {
                resumeId = id
                break
            }
        }
        let requestId = try #require(resumeId)

        // Read the stream up to the final tool call update of the child call.
        var trace: [(sequence: UInt64, event: WireTraceEvent)] = []
        var sawFinish = false
        for await event in all.events {
            if let traced = WireTraceEvent(event) { trace.append((event.sequence, traced)) }
            if case .update(.toolCallUpdate(let update)) = event.event, update.toolCallId.rawValue == "call-child-1",
                case .value(.completed) = update.status
            {
                sawFinish = true
                break
            }
        }
        #expect(sawFinish, "the stream ended before the final tool call update")
        _ = try await resume.value
        await connection.close()

        // One list in wire order: the resume request first, then the events
        // and the requests that wait on the user, merged by the one counter.
        let requests = client.recordedRequests.map { item in
            (sequence: item.arrival, event: WireTraceEvent.agentRequest(
                id: .number(Double(item.arrival)), method: "elicitation/create", sessionId: item.sessionId))
        }
        let ordered = (trace + requests).sorted { $0.sequence < $1.sequence }.map(\.event)
        let full = [WireTraceEvent.resumeRequest(id: requestId, sessionId: rootId)] + ordered
        let violations = SubagentWireTraceValidator().validate(full)
        #expect(violations.isEmpty, "\(violations)")
        // A control: the same trace with no resume response is not valid, so the
        // validator does check the trace.
        let withoutResponse = full.filter { if case .resumeResponse = $0 { false } else { true } }
        #expect(!SubagentWireTraceValidator().validate(withoutResponse).isEmpty)
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
