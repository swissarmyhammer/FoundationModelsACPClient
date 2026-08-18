import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// M6: the out-of-process deployment. `AgentProcess` spawns an external agent
// binary in its own process group and speaks ACP over its stdio. The foreign
// agent here is a /bin/sh script that speaks canned ACP v2 NDJSON. It knows
// nothing about this runtime, so it proves the wire really is the interface.

/// The shell that runs each foreign-agent script.
private let shellCommand = "/bin/sh"

/// The session id the foreign agent gives out.
private let foreignSessionID = SessionId(rawValue: "foreign-session")

/// The message id the foreign agent stamps on its one reply chunk.
private let foreignMessageID = MessageId(rawValue: "foreign-agent-msg-1")

/// The reply text the foreign agent streams for every prompt.
private let foreignReplyText = "Hello from the foreign agent."

/// A /bin/sh ACP agent: reads NDJSON requests and answers canned v2
/// responses. The client sends its requests in a known order, so the
/// response ids are the fixed values 1, 2, and 3.
private let foreignAgentScript = """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"session":{}},"info":{"name":"foreign-agent","version":"1.0.0"},"protocolVersion":2}}'
          ;;
        *'"method":"session/new"'*)
          printf '%s\\n' '{"id":2,"jsonrpc":"2.0","result":{"sessionId":"foreign-session"}}'
          ;;
        *'"method":"session/prompt"'*)
          printf '%s\\n' '{"id":3,"jsonrpc":"2.0","result":{}}'
          printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"foreign-session","update":{"content":{"text":"Hello from the foreign agent.","type":"text"},"messageId":"foreign-agent-msg-1","sessionUpdate":"agent_message_chunk"}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"foreign-session","update":{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}}}'
          ;;
      esac
    done
    """

/// Writes a foreign-agent script into a fresh temporary file.
///
/// - Parameter content: The script text.
/// - Returns: The absolute path of the script file.
private func writeScript(_ content: String) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("acp-agent-\(UUID().uuidString).sh").path
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// Polls a pid file until the agent's child reported its pid there.
///
/// - Parameter path: The pid file the agent writes.
/// - Returns: The child pid, or `nil` when the time limit ended first.
private func reportedChildPid(at path: String) async -> pid_t? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: TransportTestDeadline.limit)
    while clock.now < deadline {
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
            let parsed = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return parsed
        }
        try? await Task.sleep(for: TransportTestDeadline.pollInterval)
    }
    return nil
}

/// A relative command is refused at construction, before any spawn.
@Test func agentProcessRefusesARelativeCommand() {
    #expect(throws: AgentProcessError.commandNotAbsolute("sh")) {
        _ = try AgentProcess(command: "sh")
    }
}

/// Full session over stdio against a foreign ACP agent binary: initialize,
/// `session/new`, prompt, updates, stop. This is the test that proves the
/// "knows nothing about our runtime" claim.
@MainActor
@Test func fullSessionOverStdioToForeignAgent() async throws {
    let script = try writeScript(foreignAgentScript)
    let process = try AgentProcess(command: shellCommand, arguments: [script])
    let pid = try #require(process.processIdentifier)

    let client = SwiftUIACPClient()
    let connection = await client.connect(over: process.transport)
    #expect(client.connectionState == .connected)

    let initialized = try await connection.initialize(makeInitializeRequest())
    #expect(initialized.protocolVersion == ACPClient.supportedProtocolVersion)
    #expect(initialized.info.name == "foreign-agent")

    let cwd = try #require(AbsolutePath(rawValue: "/"))
    let session = try await connection.newSession(NewSessionRequest(cwd: cwd))
    #expect(session.sessionId == foreignSessionID)

    let replyLanded = try await promptTurnLandsReply(
        over: connection,
        client: client,
        sessionId: session.sessionId,
        messageID: foreignMessageID,
        expectedText: foreignReplyText
    )
    #expect(replyLanded)
    #expect(client.session(for: session.sessionId).lastStopReason == .endTurn)

    await connection.close()
    #expect(await eventually { client.connectionState == .disconnected })
    #expect(await eventually { !processExists(pid) })
}

/// Killing the agent process surfaces `.disconnected` observable state
/// promptly, and the dead agent is reaped — no zombie stays behind.
@MainActor
@Test func killingAgentSurfacesDisconnectedState() async throws {
    let script = try writeScript(foreignAgentScript)
    let process = try AgentProcess(command: shellCommand, arguments: [script])
    let pid = try #require(process.processIdentifier)

    let client = SwiftUIACPClient()
    let connection = try await initializedConnection(for: client, over: process.transport)

    kill(pid, SIGKILL)
    #expect(await eventually { client.connectionState == .disconnected })
    #expect(await eventually { !processExists(pid) })
    await connection.close()
}

/// A spawned agent leaves no stray pid after the host closes the
/// connection — asserted by pid, through the reap.
@MainActor
@Test func spawnedAgentLeavesNoStrayPidAfterTeardown() async throws {
    let script = try writeScript(foreignAgentScript)
    let process = try AgentProcess(command: shellCommand, arguments: [script])
    let pid = try #require(process.processIdentifier)
    #expect(processExists(pid))

    let client = SwiftUIACPClient()
    let connection = try await initializedConnection(for: client, over: process.transport)

    await connection.close()
    #expect(await eventually { !processExists(pid) })
    #expect(await eventually { process.processIdentifier == nil })
}

/// An agent that spawns a child of its own has that child cleaned up too:
/// the teardown kills the whole process group.
@Test func agentChildProcessIsCleanedUpWithTheGroup() async throws {
    let childPidPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("acp-agent-child-\(UUID().uuidString).pid").path
    let script = try writeScript(
        """
        sleep 300 &
        echo $! > "$1"
        exec sleep 300
        """
    )
    let process = try AgentProcess(command: shellCommand, arguments: [script, childPidPath])
    let pid = try #require(process.processIdentifier)

    let childPid = try #require(await reportedChildPid(at: childPidPath))
    #expect(processExists(pid))
    #expect(processExists(childPid))

    process.shutdown()
    #expect(await eventually { !processExists(pid) })
    #expect(await eventually { !processExists(childPid) })
}
