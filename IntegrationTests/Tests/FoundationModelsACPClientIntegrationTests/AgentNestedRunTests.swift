import Darwin
import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Observation
import Synchronization
import Testing

// The end-to-end acceptance tests of the sub-agent model against the REAL
// `acp-agent` binary of FoundationModelsACPAgent, with a scripted stub model
// (`ACP_AGENT_STUB_SCRIPT`, a JSON file). A root prompt makes the `agents`
// tool start a child, and the child starts a grandchild. The grandchild waits
// at a gate (a file that the test writes), so the test sees the tree while
// the runs are alive, and can stop the agent process in the middle of the run.
//
// These tests run the real `acp-agent-stub` and must pass. The public API of
// the library is the only API that the tests use.
//
// Assertions of the first test (the card lists them too):
//  1. The tree appears: the root has one child, and the child has one
//     grandchild (`parent`, `children`).
//  2. The events of the child and the grandchild are in their own models.
//  3. The grandchild runs while it waits at the gate (`workState`).
//  4. The agents call of the root links the child (`childSession`).
//  5. At the final tool call update, each child is removed (`isClosed`).
//  6. The recorded trace has zero violations of the wire trace validator.
// Assertions of the second test (kill and resume):
//  7. After the process ended and a new process resumed the root with
//     `replayFrom` start, the tree comes back.
//  8. A child is unconfirmed until its current snapshot after the response,
//     then confirmed.
//  9. The interrupted runs continue when the gate opens.
// 10. The original agents call completes, and the children are removed.

/// A client that declines each request. The trace test reads the wire only.
private final class DecliningClient: Client {
    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: .cancelled(CancelledPermissionOutcome()))
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        .object(["action": .string("decline")])
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}

    var extensionHandlers: ExtensionHandlers { ExtensionHandlers() }
}

/// The failure event of each wait: the root session closed, or its work ended
/// with no child run left (an agent that plays no script answers the prompt
/// and goes idle). A root that is idle while a child still runs is not an end.
///
/// - Parameter session: The root session.
/// - Returns: `true` when the wait must end.
@MainActor
func sessionEnded(_ session: SessionModel) -> Bool {
    if session.isClosed { return true }
    if case .idle = session.workState { return session.children.isEmpty }
    return false
}

@Suite(.acpAgentStubBuilt)
struct AgentNestedRunTests {
    /// The real agent runs a root, a child and a grandchild, and the model
    /// follows the tree to the end of the runs.
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func aNestedRunOfTheRealAgentBuildsAndEmptiesTheTree() async throws {
        do {
            let run = try NestedRun.make()
            defer { try? FileManager.default.removeItem(at: run.root) }
            let agentProcess = try await run.startAgent()
            defer { agentProcess.shutdown() }
            let model = try await run.connect(over: agentProcess, connection: firstConnection).model
            defer { await model.disconnect() }
            let session = try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: run.workspace.path)))
            let closed: @MainActor () -> Bool = { sessionEnded(session) }

            _ = try await session.prompt([.text(TextContent(text: rootMarker))])

            // 1. The tree appears.
            try await waitUntil({ session.children.count == 1 }, orFailWhen: closed)
            let child = try #require(session.children.first)
            #expect(child.parent === session)
            try await waitUntil({ child.children.count == 1 }, orFailWhen: closed)
            let grandchild = try #require(child.children.first)
            #expect(grandchild.parent === child)
            #expect(session.descendants.map(\.sessionId) == [child.sessionId, grandchild.sessionId])

            // 3. The grandchild runs while it waits at the gate.
            try await waitUntil({ grandchild.workState == .running }, orFailWhen: { closed() || isIdle(grandchild) })

            // 4. The agents call of the root links the child.
            try await waitUntil({
                session.transcript.contains { entry in
                    if case .toolCall(let call) = entry { call.childSession === child } else { false }
                }
            }, orFailWhen: closed)

            // 2. The events of each run are in its own model.
            try run.openGate()
            try await waitUntil({ agentText(in: grandchild).contains("grandchild done") },
                orFailWhen: { grandchild.isClosed })
            #expect(!agentText(in: grandchild).contains("root done"))
            try await waitUntil({ agentText(in: child).contains("child done") }, orFailWhen: { child.isClosed })
            #expect(!agentText(in: child).contains("grandchild done"))

            // 5. At the final tool call updates, each child is removed.
            try await waitUntil({ child.isClosed }, orFailWhen: closed)
            #expect(session.children.isEmpty)
            #expect(grandchild.isClosed)
        }
    }

    /// The agent process ends in the middle of the run. A new process resumes
    /// the root from the start: the tree comes back, the interrupted runs
    /// continue, and the original agents call completes.
    @Test(.timeLimit(.minutes(2)), .wireFramesOnIssue)
    @MainActor
    func aKilledAgentResumesTheNestedRunWithItsTree() async throws {
        do {
            let run = try NestedRun.make()
            defer { try? FileManager.default.removeItem(at: run.root) }
            let first = try await run.startAgent()
            let firstModel = try await run.connect(over: first, connection: firstConnection).model
            let firstSession = try await firstModel.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: run.workspace.path)))
            _ = try await firstSession.prompt([.text(TextContent(text: rootMarker))])
            try await waitUntil({ firstSession.descendants.count == 2 }, orFailWhen: { sessionEnded(firstSession) })
            let rootId = firstSession.sessionId

            // The agent process ends while the grandchild waits at the gate.
            first.shutdown()
            await firstModel.disconnect()

            let second = try await run.startAgent()
            defer { second.shutdown() }
            let model = try await run.connect(over: second, connection: secondConnection).model
            defer { await model.disconnect() }
            let session = try await model.resumeSession(
                ResumeSessionRequest(
                    cwd: AbsolutePath(rawValue: run.workspace.path),
                    sessionId: rootId,
                    replayFrom: .start(ReplayFromStart())
                )
            )
            let closed: @MainActor () -> Bool = { session.isClosed }

            // 7. The tree comes back.
            try await waitUntil({ session.descendants.count == 2 }, orFailWhen: closed)
            let child = try #require(session.children.first)
            let grandchild = try #require(child.children.first)

            // 8. A child is confirmed by its current snapshot after the response.
            try await waitUntil({ child.isWorkStateConfirmed && grandchild.isWorkStateConfirmed }, orFailWhen: closed)

            // 9. The interrupted runs continue when the gate opens.
            try await waitUntil({ grandchild.workState == .running }, orFailWhen: { closed() || isIdle(grandchild) })
            try run.openGate()

            // 10. The original agents call completes, and the children leave.
            try await waitUntil({ child.isClosed }, orFailWhen: closed)
            #expect(session.children.isEmpty)
            let calls = agentsCalls(in: session)
            #expect(!calls.isEmpty)
            #expect(calls.allSatisfy { $0.status == .completed })
        }
    }

    /// The ordered events of a nested run follow the rules of the wire trace
    /// validator.
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func theNestedRunTraceFollowsTheWireRules() async throws {
        do {
            let run = try NestedRun.make()
            defer { try? FileManager.default.removeItem(at: run.root) }
            let agentProcess = try await run.startAgent()
            defer { agentProcess.shutdown() }
            let trace = TraceTransport(wrapping: agentProcess.transport, connection: firstConnection)
            let connection = await ClientSideConnection(stream: trace) { _ in DecliningClient() }
            let all = connection.subscribeToAllSessions()
            _ = try await connection.initialize(.integrationTest(clientName: nestedClientName))
            let created = try await connection.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: run.workspace.path)))
            _ = try await connection.prompt(
                PromptRequest(prompt: [.text(TextContent(text: rootMarker))], sessionId: created.sessionId))
            try run.openGate()

            // Read until the root work is idle. With no scripted run, that
            // comes at once, and no child was announced.
            var announced = false
            for await event in all.events {
                if case .update(.subagentUpdate) = event.event { announced = true }
                if event.sessionId == created.sessionId, case .update(.stateUpdate(.idle)) = event.event {
                    break
                }
            }
            await connection.close()
            // The agent must announce the child, and the trace must follow the
            // rules.
            #expect(announced, "the agent announced no child")
            trace.expectValidTrace()
        }
    }
}
