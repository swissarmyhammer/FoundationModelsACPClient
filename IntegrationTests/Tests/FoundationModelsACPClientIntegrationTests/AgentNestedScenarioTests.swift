import Darwin
import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Testing

// The remaining acceptance tests of the sub-agent model against the REAL
// `acp-agent` with the scripted stub model (`ACP_AGENT_STUB_SCRIPT`). Each
// test records the frames of its connection with `TraceTransport`, and checks
// the trace with `SubagentWireTraceValidator`. The tests are RED until the
// agent package lands the scripted stub model and the behavior they name; each
// carries the `.bug` trait with the card that lists the assertions.
//
// The script steps that these tests assume, beside the steps of the agent
// contract (`text`, `reasoning`, `toolCall`, `gate`):
// - `{"elicit": "<message>"}`: the run asks a form question and waits.

/// The count of the sibling children of the sibling script.
private let siblingCount = 2

/// The count of the sessions below the root of a nested run: the child and the
/// grandchild.
private let nestedSessionCount = 2

/// The marker of each extra scripted session.
private let childAMarker = "CHILD-A-MARKER"
private let childBMarker = "CHILD-B-MARKER"

/// A started agent process, the model over its traced connection, and the
/// trace.
@MainActor
private struct TracedRun {
    let process: AgentProcess
    let trace: TraceTransport
    let model: ConnectionModel

    /// Starts an agent process, connects a model over a traced transport, and
    /// initializes it.
    ///
    /// - Parameter run: The files of the run.
    /// - Returns: The started run.
    /// - Throws: The error of the start or of `initialize`.
    static func start(_ run: NestedRun) async throws -> TracedRun {
        let process = try await run.startAgent()
        let trace = TraceTransport(wrapping: process.transport)
        let model = try await connectedModel(over: trace, clientName: nestedClientName)
        return TracedRun(process: process, trace: trace, model: model)
    }

    /// Ends the agent process and closes the connection.
    func cleanUp() async {
        process.shutdown()
        await model.disconnect()
    }

    /// Checks the recorded trace against the wire rules.
    func expectValidTrace() {
        #expect(trace.decodeFailures.isEmpty, "\(trace.decodeFailures)")
        let violations = SubagentWireTraceValidator().validate(trace.events)
        #expect(violations.isEmpty, "\(violations)")
    }
}

/// The script of two sibling children of the root. Each waits at its own gate.
///
/// - Parameter gate: Gives the path of a gate by name.
/// - Returns: The script.
private func siblingScript(_ gate: (String) -> String) -> String {
    NestedScript.scriptJSON([
        NestedScript.rootSession(starts: [
            NestedScript.startAgentStep("researcher", prompt: "\(childAMarker) work"),
            NestedScript.startAgentStep("reviewer", prompt: "\(childBMarker) work"),
        ]),
        NestedScript.scriptedSession(marker: childAMarker, passes: [["{\"gate\": \"\(gate("a"))\"}", "{\"text\": \"a done\"}"]]),
        NestedScript.scriptedSession(marker: childBMarker, passes: [["{\"gate\": \"\(gate("b"))\"}", "{\"text\": \"b done\"}"]]),
    ])
}

/// The script of a root with one child that asks a form question.
///
/// - Parameter gate: Gives the path of a gate by name. The script holds none.
/// - Returns: The script.
private func askingScript(_ gate: (String) -> String) -> String {
    NestedScript.scriptJSON([
        NestedScript.rootSession(starts: [NestedScript.startAgentStep("researcher", prompt: "\(childMarker) ask")]),
        NestedScript.scriptedSession(
            marker: childMarker,
            passes: [[
                "{\"elicit\": \"Which file?\"}", "{\"text\": \"after question\"}",
            ]]),
    ])
}

/// Starts a traced run over a script and opens a session.
///
/// - Parameter script: Builds the script from the gate paths.
/// - Returns: The files of the run, the started run, and the session.
/// - Throws: The error of the start or of `session/new`.
@MainActor
private func startSession(
    script: @escaping (_ gate: (String) -> String) -> String
) async throws -> (NestedRun, TracedRun, SessionModel) {
    let run = try NestedRun.make(script: script)
    let (started, session) = try await openSession(run)
    return (run, started, session)
}

/// Starts a traced run over the files of a run and opens a session.
///
/// - Parameter run: The files of the run.
/// - Returns: The started run, and the session.
/// - Throws: The error of the start or of `session/new`.
@MainActor
private func openSession(_ run: NestedRun) async throws -> (TracedRun, SessionModel) {
    let started = try await TracedRun.start(run)
    let session = try await started.model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: run.workspace.path)))
    return (started, session)
}

/// Starts a new agent process over the files of a run, and resumes the root.
///
/// - Parameters:
///   - run: The files of the run.
///   - rootId: The id of the root session.
/// - Returns: The started run, and the resumed root session.
/// - Throws: The error of the start or of the resume.
@MainActor
private func resumeInNewProcess(_ run: NestedRun, rootId: SessionId) async throws -> (TracedRun, SessionModel) {
    let second = try await TracedRun.start(run)
    let session = try await NestedRun.resumeRoot(second.model, run, sessionId: rootId)
    return (second, session)
}

/// The child and the grandchild of the root of a nested run.
///
/// - Parameter session: The root session.
/// - Returns: The child, and its child.
/// - Throws: The error of `#require` when the tree is not there.
@MainActor
private func childAndGrandchild(of session: SessionModel) throws -> (child: SessionModel, grandchild: SessionModel) {
    let child = try #require(session.children.first)
    let grandchild = try #require(child.children.first)
    return (child, grandchild)
}

/// The first half of a nested run: a started agent, a session with the root
/// prompt, and the wait for the child and the grandchild.
///
/// - Parameter run: The files of the run.
/// - Returns: The started run, the root session, and the root id.
/// - Throws: The error of the start, or of a wait.
@MainActor
private func startNestedRun(_ run: NestedRun) async throws -> (TracedRun, SessionModel, SessionId) {
    let (started, session) = try await openSession(run)
    _ = try await session.prompt([.text(TextContent(text: rootMarker))])
    try await waitUntil({ session.descendants.count == nestedSessionCount }, orFailWhen: { sessionEnded(session) })
    return (started, session, session.sessionId)
}

struct AgentNestedScenarioTests {
    /// A cancel of one child ends only that child. A cancel of the parent
    /// leaves a background child running.
    @Test(.bug("kanban://task/01M6HCB90N3N6V8VTCQKG9T45M", "Acceptance tests against the real acp-agent"), .timeLimit(.minutes(2)))
    @MainActor
    func aCancelOfOneChildEndsOnlyThatChild() async throws {
        let (run, started, session) = try await startSession(script: siblingScript)
        defer { await started.cleanUp() }
        let ended: @MainActor () -> Bool = { sessionEnded(session) }

        _ = try await session.prompt([.text(TextContent(text: rootMarker))])
        try await waitUntil({ session.children.count == siblingCount }, orFailWhen: ended)
        let first = try #require(session.children.first)
        let second = try #require(session.children.last)
        try await waitUntil({ first.workState == .running && second.workState == .running }, orFailWhen: ended)

        // The cancel of the first child: it goes idle with the stop reason
        // `cancelled`, its tool call ends, and its sibling and the root go on.
        try await waitUntil({ first.capabilities?.cancel != nil }, orFailWhen: ended)
        try await first.cancel()
        try await waitUntil({ first.workState == .idle(stopReason: .cancelled, error: nil) }, orFailWhen: ended)
        #expect(second.workState == .running)
        #expect(!second.isClosed)
        if case .idle = session.workState {
            Issue.record("the root went idle with a running child")
        }

        // The cancel of the parent leaves the running background child. The
        // second child starts about 5.7 seconds after the first, inline at
        // first. Cancel only when the second child is a background item of the
        // root. With only background work left, a root cancel sends no state
        // update, so the test does not wait for an idle root.
        try await started.trace.waitForIncomingFrame(containing: "scripted-call-2")
        try await session.cancel()
        #expect(second.workState == .running)
        #expect(!second.isClosed)

        // The sibling ends when its gate opens, and the trace is complete.
        try run.openGate(named: "b")
        try await waitUntil({ second.isClosed }, orFailWhen: { session.isClosed })
        started.expectValidTrace()
        try FileManager.default.removeItem(at: run.root)
    }

    /// A form question of a child shows under the child id once, and its
    /// answer reaches the child. The agent sends no permission request.
    @Test(.bug("kanban://task/01M6HCB90N3N6V8VTCQKG9T45M", "Acceptance tests against the real acp-agent"), .timeLimit(.minutes(2)))
    @MainActor
    func aChildQuestionShowsUnderTheChildOnceAndItsAnswerReachesIt() async throws {
        let (run, started, session) = try await startSession(script: askingScript)
        defer { await started.cleanUp() }
        let ended: @MainActor () -> Bool = { sessionEnded(session) }

        _ = try await session.prompt([.text(TextContent(text: rootMarker))])
        try await waitUntil({ session.children.count == 1 }, orFailWhen: ended)
        let child = try #require(session.children.first)

        // The form question: once, under the child.
        try await waitUntil({ !child.pendingElicitations.isEmpty }, orFailWhen: ended)
        #expect(child.pendingElicitations.count == 1)
        #expect(session.pendingElicitations.isEmpty)
        let question = try #require(child.pendingElicitations.first)
        // The agent ends the pass on a decline by design, so the test accepts.
        // The form has one required string field, `answer`.
        child.acceptElicitation(question.id, content: .object(["answer": .string("x.txt")]))
        try await waitUntil({ agentText(in: child).contains("after question") }, orFailWhen: ended)
        #expect(agentText(in: child).contains("after question"))

        // The trace holds the whole run only after the child ends.
        try await waitUntil({ child.isClosed }, orFailWhen: { session.isClosed })
        started.expectValidTrace()
        try FileManager.default.removeItem(at: run.root)
    }

    /// A hot resume of a live session tree: the history comes before the
    /// response, the running child keeps running, and the current child
    /// snapshots come after the response.
    @Test(.bug("kanban://task/01M6HCB90N3N6V8VTCQKG9T45M", "Acceptance tests against the real acp-agent"), .timeLimit(.minutes(2)))
    @MainActor
    func aHotResumeKeepsTheRunningChildRunning() async throws {
        let run = try NestedRun.make()
        let (started, session, rootId) = try await startNestedRun(run)
        defer { await started.cleanUp() }

        // The same connection resumes the live session from the start.
        let resumed = try await NestedRun.resumeRoot(started.model, run, sessionId: rootId)
        #expect(resumed === session)
        #expect(!resumed.isReplaying)
        try await waitUntil({ session.descendants.count == nestedSessionCount }, orFailWhen: { session.isClosed })
        let (child, grandchild) = try childAndGrandchild(of: session)
        try await waitUntil(
            { child.isWorkStateConfirmed && grandchild.isWorkStateConfirmed }, orFailWhen: { session.isClosed })
        #expect(grandchild.workState == .running)

        // The run goes on after the resume.
        try run.openGate()
        try await waitUntil({ child.isClosed }, orFailWhen: { session.isClosed })
        started.expectValidTrace()
        try FileManager.default.removeItem(at: run.root)
    }

    /// A child whose definition is gone after a restart shows unknown with a
    /// restore failure, and so do its descendants, while the root resumes.
    @Test(.bug("kanban://task/01M6HCB90N3N6V8VTCQKG9T45M", "Acceptance tests against the real acp-agent"), .timeLimit(.minutes(2)))
    @MainActor
    func aChildWithNoDefinitionAfterARestartShowsUnknownWithItsReason() async throws {
        let run = try NestedRun.make()
        let (first, _, rootId) = try await startNestedRun(run)
        // The cleanup is idempotent: it covers a throw before the manual end.
        defer { await first.cleanUp() }
        first.process.shutdown()
        await first.model.disconnect()

        // The definition of the child is gone when the agent starts again.
        try FileManager.default.removeItem(
            at: run.workspace.appendingPathComponent(".agents/agents/researcher", isDirectory: true))
        let (second, session) = try await resumeInNewProcess(run, rootId: rootId)
        defer { await second.cleanUp() }

        // The root resumed, and the tree has the child and the grandchild as
        // unknown, each with its reason.
        #expect(session.workState == .running)
        try await waitUntil({ session.descendants.count == nestedSessionCount }, orFailWhen: { session.isClosed })
        let (child, grandchild) = try childAndGrandchild(of: session)
        try await waitUntil(
            { child.restoreFailure != nil && grandchild.restoreFailure != nil }, orFailWhen: { session.isClosed })
        #expect(child.workState == .unknown)
        #expect(grandchild.workState == .unknown)
        second.expectValidTrace()
        try FileManager.default.removeItem(at: run.root)
    }

    /// An orderly quit (SIGTERM) of the agent process, and a new process: the
    /// interrupted nested runs come back, and the ORIGINAL agents call
    /// completes.
    @Test(.bug("kanban://task/01M6HCB90N3N6V8VTCQKG9T45M", "Acceptance tests against the real acp-agent"), .timeLimit(.minutes(2)))
    @MainActor
    func anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall() async throws {
        let run = try NestedRun.make()
        let (first, _, rootId) = try await startNestedRun(run)
        // The cleanup is idempotent: it covers a throw before the manual end.
        defer { await first.cleanUp() }

        let pid = try #require(first.process.processIdentifier)
        kill(pid, SIGTERM)
        _ = try await first.process.waitForExit()
        await first.model.disconnect()
        first.expectValidTrace()

        let (second, session) = try await resumeInNewProcess(run, rootId: rootId)
        defer { await second.cleanUp() }
        try await waitUntil({ session.descendants.count == nestedSessionCount }, orFailWhen: { session.isClosed })
        let (child, grandchild) = try childAndGrandchild(of: session)
        try await waitUntil({ grandchild.workState == .running }, orFailWhen: { session.isClosed })

        // The interrupted runs continue, and the original agents call ends.
        try run.openGate()
        try await waitUntil({ child.isClosed }, orFailWhen: { session.isClosed })
        let agentsCalls = session.transcript.compactMap { entry -> ToolCallEntry? in
            if case .toolCall(let call) = entry, call.name == "agents" { call } else { nil }
        }
        #expect(!agentsCalls.isEmpty)
        #expect(agentsCalls.allSatisfy { $0.status == .completed })
        second.expectValidTrace()
        try FileManager.default.removeItem(at: run.root)
    }
}
