import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsKanban
import LiveAgentServerSupport

// `registerHostTools(_:)` of `RoutedACPAgent` is internal. Its doc comment
// names the tests and an in-process host as its users. This server is a
// test fixture, and `swift build` compiles the debug configuration with
// testability on, so the import reaches the call.
@testable import FoundationModelsACPAgent

/// The agent of the GraphQL integration test of FoundationModelsACPClient,
/// served over stdio.
///
/// The agent is the real `RoutedACPAgent` of FoundationModelsACPAgent, so
/// the test reaches the real GraphQL tunnel (`GraphQLTunnel`) of the agent.
/// The agent uses the stub model path of `ComposedAgent`, so it loads no
/// model. Host tools give each session the small ``ProbeEndpoint``, and the
/// `kanban` endpoint (`KanbanGraph`) over the board of the working
/// directory.
///
/// Usage: `graphql-tunnel-server <state-directory> <working-directory>`. The
/// server writes its user layer under the state directory, and loads the
/// configuration from the working directory.
///
/// stdout carries only ACP frames. The server ends when the client closes
/// the connection.
@main
enum GraphQLTunnelServer {
    /// The dotfolder name of the agent. The configuration stack and the
    /// transcripts of the agent use this name.
    static let agentName = "acp-client-graphql-integration"

    /// Makes the agent, serves it on stdin and stdout, and returns when the
    /// connection closed and the agent closed its sessions.
    ///
    /// A start error (`LaunchArguments.Failure` for a wrong argument list, or
    /// the error of the file write, of the configuration load, of the agent
    /// make or of the board open) does not get out of this function:
    /// `ServerStart` writes the reason to stderr and exits with status 1.
    static func main() async {
        let (composed, board) = await ServerStart.make {
            try await makeAgent(LaunchArguments(commandLine: CommandLine.arguments))
        }
        let connection = await composed.serve(over: StdioTransport())
        _ = await connection.closed
        await composed.waitForConnectionTeardown()
        await composed.closeOpenSessions()
        await board.close()
    }

    /// Makes the agent and the board of the working directory: writes the
    /// user layer under the state directory, composes the agent on the stub
    /// model path, opens the board, and registers the host tools.
    ///
    /// - Parameter arguments: The directories of the launch.
    /// - Returns: The composed agent, and the board that its `kanban`
    ///   endpoint serves.
    /// - Throws: The error of the file write, of the configuration load, of
    ///   the agent make or of the board open.
    private static func makeAgent(
        _ arguments: LaunchArguments
    ) async throws -> (composed: ComposedAgent, board: KanbanGraph) {
        let home = try IntegrationAgentHome.make(
            under: arguments.stateDirectory, userConfigYAML: IntegrationAgentHome.offlineToolsYAML)
        let composed = try await ComposedAgent.compose(
            name: try DotfolderName(agentName),
            workingDirectory: arguments.workingDirectory,
            home: home,
            mode: .open,
            environment: [:],
            modelSource: .stub)
        let board = try await KanbanHost.shared.session(workingDirectory: arguments.workingDirectory, actor: agentName)
        await composed.agent.registerHostTools([ProbeTool(), KanbanTool(graph: board)])
        return (composed, board)
    }
}
