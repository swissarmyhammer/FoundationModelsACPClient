import Darwin
import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import Testing

// The remaining acceptance tests of the sub-agent model against the REAL
// `acp-agent` with the scripted stub model (`ACP_AGENT_STUB_SCRIPT`). Each
// test records the frames of its connection with `TraceTransport`, and checks
// the trace with `SubagentWireTraceValidator`. These tests run the real
// `acp-agent-stub` and must pass.
//
// The script steps that these tests assume, beside the steps of the agent
// contract (`text`, `reasoning`, `toolCall`, `gate`):
// - `{"elicit": "<message>"}`: the run asks a form question and waits.
// - `{"permission": "<title>"}`: the run asks a permission and waits.

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
    /// - Parameters:
    ///   - run: The files of the run.
    ///   - connection: The name of the connection in the text of an issue.
    /// - Returns: The started run.
    /// - Throws: The error of the start or of `initialize`.
    static func start(_ run: NestedRun, connection: String) async throws -> TracedRun {
        let process = try await run.startAgent()
        let connected = try await run.connect(over: process, connection: connection)
        return TracedRun(process: process, trace: connected.trace, model: connected.model)
    }

    /// Ends the agent process and closes the connection.
    func cleanUp() async {
        process.shutdown()
        await model.disconnect()
    }

    /// Checks the recorded trace against the wire rules. The issue of a
    /// violation holds the ordered trace.
    ///
    /// - Parameter sourceLocation: The place that an issue names.
    func expectValidTrace(sourceLocation: SourceLocation = #_sourceLocation) {
        trace.expectValidTrace(sourceLocation: sourceLocation)
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

/// The step of a child that asks a form question.
private let elicitStep = "{\"elicit\": \"Which file?\"}"

/// The text that the asking child plays after its question.
private let textAfterQuestion = "after question"

/// The title of the permission request of the permission step.
private let permissionTitle = "Run the tool?"

/// The step of a child that asks a permission.
private let permissionStep = "{\"permission\": \"\(permissionTitle)\"}"

/// The text that the child plays after its permission request.
private let textAfterPermission = "after permission"

/// The script of a root with one child. The child plays a first step that
/// asks, and then a text.
///
/// - Parameters:
///   - childStep: The first step of the child, a question or a permission.
///   - textAfter: The text that the child plays after the first step.
///   - gate: Gives the path of a gate by name. The script holds none.
/// - Returns: The script.
private func askingScript(childStep: String, textAfter: String, gate: (String) -> String) -> String {
    NestedScript.scriptJSON([
        NestedScript.rootSession(starts: [NestedScript.startAgentStep("researcher", prompt: "\(childMarker) ask")]),
        NestedScript.scriptedSession(
            marker: childMarker,
            passes: [[childStep, "{\"text\": \"\(textAfter)\"}"]]),
    ])
}

/// Prompts the root, and waits for its one child.
///
/// - Parameter session: The root session.
/// - Returns: The child.
/// - Throws: The error of the prompt, of the wait, or of `#require`.
@MainActor
private func promptAndAwaitChild(of session: SessionModel) async throws -> SessionModel {
    _ = try await session.prompt([.text(TextContent(text: rootMarker))])
    try await waitUntil({ session.children.count == 1 }, orFailWhen: { sessionEnded(session) })
    return try #require(session.children.first)
}

/// Prompts the root of the question script, and waits for the form question of
/// the child. The question is pending once under the child, and never under
/// the root.
///
/// - Parameter session: The root session.
/// - Returns: The child, and its pending question.
/// - Throws: The error of the prompt, of a wait, or of `#require`.
@MainActor
private func awaitChildQuestion(of session: SessionModel) async throws -> (SessionModel, PendingElicitation) {
    let child = try await promptAndAwaitChild(of: session)
    try await waitUntil({ !child.pendingElicitations.isEmpty }, orFailWhen: { sessionEnded(session) })
    #expect(child.pendingElicitations.count == 1)
    #expect(session.pendingElicitations.isEmpty)
    return (child, try #require(child.pendingElicitations.first))
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
    let started = try await TracedRun.start(run, connection: firstConnection)
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
    let second = try await TracedRun.start(run, connection: secondConnection)
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

@Suite(.acpAgentStubBuilt)
struct AgentNestedScenarioTests {
    /// A cancel of one child ends only that child. A cancel of the parent
    /// leaves a background child running.
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func aCancelOfOneChildEndsOnlyThatChild() async throws {
        let (run, started, session) = try await startSession(script: siblingScript)
        defer { try? FileManager.default.removeItem(at: run.root) }
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
        let firstCall = try #require(agentsCalls(in: session).first { $0.childSession === first })
        try await first.cancel()
        try await waitUntil({ first.workState == .idle(stopReason: .cancelled, error: nil) }, orFailWhen: ended)
        // The linked agents call of the cancelled child ends: its status is
        // final, and the child leaves the tree.
        try await waitUntil({ first.isClosed }, orFailWhen: ended)
        #expect(firstCall.status == .completed || firstCall.status == .failed)
        #expect(!session.children.contains { $0 === first })
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
    }

    /// A form question of a child shows under the child id once, and its
    /// answer reaches the child. The agent sends no permission request.
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func aChildQuestionShowsUnderTheChildOnceAndItsAnswerReachesIt() async throws {
        let (run, started, session) = try await startSession(script: { askingScript(childStep: elicitStep, textAfter: textAfterQuestion, gate: $0) })
        defer { try? FileManager.default.removeItem(at: run.root) }
        defer { await started.cleanUp() }
        let (child, question) = try await awaitChildQuestion(of: session)

        // The form has one required string field, `answer`.
        child.acceptElicitation(question.id, content: .object(["answer": .string("x.txt")]))
        try await waitUntil({ agentText(in: child).contains(textAfterQuestion) }, orFailWhen: { sessionEnded(session) })
        #expect(agentText(in: child).contains(textAfterQuestion))

        // The trace holds the whole run only after the child ends.
        try await waitUntil({ child.isClosed }, orFailWhen: { session.isClosed })
        started.expectValidTrace()
    }

    /// A permission request of a child shows under the child id once, never
    /// under the root, and its answer reaches the child: the run goes on.
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func aChildPermissionRequestShowsUnderTheChildOnceAndItsAnswerReachesIt() async throws {
        let (run, started, session) = try await startSession(script: { askingScript(childStep: permissionStep, textAfter: textAfterPermission, gate: $0) })
        defer { try? FileManager.default.removeItem(at: run.root) }
        defer { await started.cleanUp() }
        let ended: @MainActor () -> Bool = { sessionEnded(session) }
        let child = try await promptAndAwaitChild(of: session)

        // The request is pending once under the child, and never under the root.
        try await waitUntil({ !child.pendingPermissions.isEmpty }, orFailWhen: ended)
        #expect(child.pendingPermissions.count == 1)
        #expect(session.pendingPermissions.isEmpty)
        let pending = try #require(child.pendingPermissions.first)
        #expect(pending.request.sessionId == child.sessionId)
        #expect(pending.request.title == permissionTitle)

        // The selection reaches the child: the text after the permission plays.
        let allow = try #require(pending.request.options.first { $0.kind == .allowOnce })
        await child.selectPermission(pending.id, option: allow.optionId)
        try await waitUntil({ agentText(in: child).contains(textAfterPermission) }, orFailWhen: ended)
        #expect(child.pendingPermissions.isEmpty)
        #expect(session.pendingPermissions.isEmpty)

        // The trace holds the whole run only after the child ends.
        try await waitUntil({ child.isClosed }, orFailWhen: { session.isClosed })
        started.expectValidTrace()
    }

    /// A decline of the form question of a child reaches the child: the child
    /// ends its pass, and the text after the question never plays.
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func aDeclinedChildQuestionEndsTheChildPassWithoutTheTextAfterIt() async throws {
        let (run, started, session) = try await startSession(script: { askingScript(childStep: elicitStep, textAfter: textAfterQuestion, gate: $0) })
        defer { try? FileManager.default.removeItem(at: run.root) }
        defer { await started.cleanUp() }
        let (child, question) = try await awaitChildQuestion(of: session)

        child.declineElicitation(question.id)
        try await waitUntil({ child.isClosed }, orFailWhen: { session.isClosed })
        #expect(!agentText(in: child).contains(textAfterQuestion))
        #expect(child.pendingElicitations.isEmpty)

        started.expectValidTrace()
    }

    /// A hot resume of a live session tree: the history comes before the
    /// response, the running child keeps running, and the current child
    /// snapshots come after the response.
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func aHotResumeKeepsTheRunningChildRunning() async throws {
        let run = try NestedRun.make()
        defer { try? FileManager.default.removeItem(at: run.root) }
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
    }

    /// A child whose definition is gone after a restart shows unknown with a
    /// restore failure, and so do its descendants, while the root resumes.
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func aChildWithNoDefinitionAfterARestartShowsUnknownWithItsReason() async throws {
        let run = try NestedRun.make()
        defer { try? FileManager.default.removeItem(at: run.root) }
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
        // unknown, each with its reason. The root is idle: a child that failed
        // to restore adds no foreground work, and idle allows background work.
        #expect(session.workState == .idle(stopReason: nil, error: nil))
        try await waitUntil({ session.descendants.count == nestedSessionCount }, orFailWhen: { session.isClosed })
        let (child, grandchild) = try childAndGrandchild(of: session)
        try await waitUntil(
            { child.restoreFailure != nil && grandchild.restoreFailure != nil }, orFailWhen: { session.isClosed })
        #expect(child.workState == .unknown)
        #expect(grandchild.workState == .unknown)
        second.expectValidTrace()
    }

    /// An orderly quit (SIGTERM) of the agent process, and a new process: the
    /// interrupted nested runs come back, and the ORIGINAL agents call
    /// completes.
    @Test(.timeLimit(.minutes(2)), .wireFramesOnIssue)
    @MainActor
    func anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall() async throws {
        let run = try NestedRun.make()
        defer { try? FileManager.default.removeItem(at: run.root) }
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
        let calls = agentsCalls(in: session)
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0.status == .completed })
        second.expectValidTrace()
    }
}
