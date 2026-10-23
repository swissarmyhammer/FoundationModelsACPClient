import Foundation
import FoundationModelsACP
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
/// model. A host tool gives each session the small ``ProbeEndpoint``.
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
    /// - Throws: `LaunchArguments.Failure` for a wrong argument list, or
    ///   the error of the file write, of the configuration load or of the
    ///   profile resolution.
    static func main() async throws {
        let arguments = try LaunchArguments(commandLine: CommandLine.arguments)
        let home = try IntegrationAgentHome.make(
            under: arguments.stateDirectory, userConfigYAML: IntegrationAgentHome.offlineToolsYAML)
        let composed = try await ComposedAgent.compose(
            name: try DotfolderName(agentName),
            workingDirectory: arguments.workingDirectory,
            home: home,
            environment: [:],
            modelSource: .stub)
        await composed.agent.registerHostTools([ProbeTool()])
        let connection = await composed.serve(over: StdioTransport())
        _ = await connection.closed
        await composed.waitForConnectionTeardown()
        await composed.closeOpenSessions()
    }
}
