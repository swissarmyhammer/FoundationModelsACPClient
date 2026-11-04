import Foundation
import FoundationModelsACP
import FoundationModelsACPClient

/// The prefix of the name of the temporary directory of each test.
let nestedTemporaryDirectoryPrefix = "acp-client-agent-nested-integration"

/// The client name that each test gives in `initialize`.
let nestedClientName = "acp-client-agent-nested-integration-test"

/// The markers that select the scripted pass of each session by its first
/// prompt.
let rootMarker = "ROOT-MARKER"
let childMarker = "CHILD-MARKER"
let grandchildMarker = "GRANDKID-MARK"

/// The environment variable that gives the stub script to `acp-agent`.
let stubScriptVariable = "ACP_AGENT_STUB_SCRIPT"

/// The files and the processes of one nested run.
struct NestedRun {
    /// The temporary directory of the test.
    let root: URL

    /// The working directory of the sessions. It holds the agent definitions.
    let workspace: URL

    /// The gate of the grandchild: the pass waits until this file exists.
    let gate: URL

    /// The environment of the agent process.
    let environment: [String: String]

    /// Makes the directories, the agent definitions and the stub script.
    ///
    /// - Returns: The run.
    /// - Throws: The error of a file write.
    static func make(script makeScript: ((_ gate: (String) -> String) -> String)? = nil) throws -> NestedRun {
        let root = try IntegrationTemporaryDirectory.make(prefix: nestedTemporaryDirectoryPrefix)
        let workspace = try IntegrationTemporaryDirectory.makeWorkspace(in: root)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let gate = root.appendingPathComponent("grandchild.gate")
        let gatePath: (String) -> String = { name in root.appendingPathComponent("\(name).gate").path }
        for name in ["researcher", "reviewer"] {
            let folder = workspace.appendingPathComponent(".agents/agents/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Only the researcher starts other agents, so it holds the Agent tool. An explicit
            // tools line limits the agent to its list, and a scripted elicit step plays one runCode call.
            let toolsLine = name == "researcher" ? "tools: Agent, runCode\n" : ""
            try "---\nname: \(name)\ndescription: The \(name) test agent.\n\(toolsLine)---\n\nDo the task.\n"
                .write(to: folder.appendingPathComponent("AGENT.md"), atomically: true, encoding: .utf8)
        }
        let defaultScript = NestedScript.scriptJSON([
            NestedScript.rootSession(starts: [NestedScript.startAgentStep("researcher", prompt: "\(childMarker) research")]),
            NestedScript.scriptedSession(
                marker: childMarker,
                passes: [[NestedScript.startAgentStep("reviewer", prompt: "\(grandchildMarker) review"), "{\"text\": \"child done\"}"]]),
            NestedScript.scriptedSession(
                marker: grandchildMarker,
                passes: [["{\"gate\": \"\(gate.path)\"}", "{\"text\": \"grandchild done\"}"]]),
        ])
        let script = makeScript?(gatePath) ?? defaultScript
        let scriptFile = root.appendingPathComponent("stub-script.json")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment[stubScriptVariable] = scriptFile.path
        // The stub executable plays the script and loads no model. It reads
        // its configuration from the XDG config home.
        environment["XDG_CONFIG_HOME"] = home.path
        return NestedRun(root: root, workspace: workspace, gate: gate, environment: environment)
    }

    /// Starts a new `acp-agent-stub acp` process over stdio.
    ///
    /// - Returns: The agent process.
    /// - Throws: The error of the build or of the start.
    func startAgent() async throws -> AgentProcess {
        try await LiveAgentServerBuild(rootDirectory: root).startExecutable(
            LiveAgentServerBuild.acpAgentStub,
            arguments: ["acp"],
            environment: environment,
            currentDirectory: workspace
        )
    }

    /// Starts a connection model over an agent process and initializes it.
    ///
    /// - Parameter process: The agent process.
    /// - Returns: The connected model, after `initialize`.
    /// - Throws: The error of `initialize`.
    @MainActor
    func connect(over process: AgentProcess) async throws -> ConnectionModel {
        try await connectedModel(over: process.transport, clientName: nestedClientName)
    }

    /// Opens a gate by name: the pass that waits for it goes on.
    ///
    /// - Parameter name: The name that the script gave to the gate.
    /// - Throws: The error of the file write.
    func openGate(named name: String) throws {
        try Data().write(to: root.appendingPathComponent("\(name).gate"))
    }

    /// Opens the gate of the grandchild.
    ///
    /// - Throws: The error of the file write.
    func openGate() throws {
        try openGate(named: "grandchild")
    }
}

/// The builders of the stub script JSON.
enum NestedScript {
    /// The JSON of the step that starts an agent with the `agents` tool.
    ///
    /// - Parameters:
    ///   - name: The agent definition.
    ///   - prompt: The prompt of the run.
    /// - Returns: The step.
    static func startAgentStep(_ name: String, prompt: String) -> String {
        """
        {"toolCall": {"name": "agents", "arguments": {"op": "start agent", "name": "\(name)", "prompt": "\(prompt)"}}}
        """
    }

    /// The JSON of one scripted session.
    ///
    /// - Parameters:
    ///   - marker: The text that the first prompt of the session holds.
    ///   - passes: The passes, each a list of step JSON.
    /// - Returns: The session entry.
    static func scriptedSession(marker: String, passes: [[String]]) -> String {
        let body = passes.map { "[" + $0.joined(separator: ", ") + "]" }.joined(separator: ", ")
        return "{\"match\": {\"promptContains\": \"\(marker)\"}, \"passes\": [\(body)]}"
    }

    /// The JSON of a script.
    ///
    /// - Parameter sessions: The scripted sessions.
    /// - Returns: The script.
    static func scriptJSON(_ sessions: [String]) -> String {
        "{\"sessions\": [" + sessions.joined(separator: ",\n") + "]}"
    }

    /// The scripted root session: one pass that starts the given agents and then
    /// ends with its text. The text stays in the same pass, because a second pass
    /// plays only on a new prompt or mail.
    ///
    /// - Parameter starts: The steps that start agents.
    /// - Returns: The session entry.
    static func rootSession(starts: [String]) -> String {
        scriptedSession(marker: rootMarker, passes: [starts + ["{\"text\": \"root done\"}"]])
    }
}

/// Resumes the root session of a nested run from the start.
///
/// - Parameters:
///   - model: The connected model.
///   - run: The files of the run.
///   - sessionId: The id of the root session.
/// - Returns: The model of the session.
/// - Throws: The error of the resume.
extension NestedRun {
    @MainActor
    static func resumeRoot(_ model: ConnectionModel, _ run: NestedRun, sessionId: SessionId) async throws -> SessionModel {
        try await model.resumeSession(
            ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: run.workspace.path),
                sessionId: sessionId,
                replayFrom: .start(ReplayFromStart())
            )
        )
    }
}
