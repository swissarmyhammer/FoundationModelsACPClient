import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsRouter

/// The real agent of the integration test of FoundationModelsACPClient,
/// served over stdio.
///
/// The agent is `RoutedACPAgent` of FoundationModelsACPAgent, with a router
/// that loads the real model and decodes greedy, as `LiveAgent` of
/// FoundationModelsACPAgent does, so that each run gives the same result.
/// The `acp-agent` executable serves the same agent, but it has no greedy
/// option.
///
/// Usage: `live-agent-server <state-directory> <working-directory>`. The
/// server writes its user layer and its recordings under the state
/// directory, and loads the configuration from the working directory.
///
/// stdout carries only ACP frames. The server ends when the client closes
/// the connection.
@main
enum LiveAgentServer {
    /// The dotfolder name of the agent. The configuration stack and the
    /// transcripts of the agent use this name.
    static let agentName = "acp-client-integration"

    /// The model of the `standard` slot, which answers the prompt. It is the
    /// smallest generation model that the integration suites of
    /// FoundationModelsACPAgent load: it is the shipped `flash` slot that
    /// `TierThreeFixture` resolves.
    static let standardModel = "mlx-community/Qwen3-4B-4bit"

    /// The model of the `flash` slot. The router refuses a profile that names
    /// one model for the `standard` slot and the `flash` slot, so this slot
    /// names a smaller model. The `agents-demo` example of
    /// FoundationModelsAgents uses the same pair.
    static let flashModel = "mlx-community/Qwen3-1.7B-4bit"

    /// The user-layer `config.yaml` of the agent.
    ///
    /// The profile names two small models. The skills marketplace list is
    /// empty and the code context is off, so the turn does not use the
    /// network and does not index the workspace.
    static let userConfigYAML = """
        tools:
          codeContext: false
          skills:
            marketplaces: []
        profile:
          standard: ["\(standardModel)"]
          flash: ["\(flashModel)"]
        """

    /// Makes the agent, serves it on stdin and stdout, and returns when the
    /// connection closed and the agent finished its teardown.
    ///
    /// - Throws: ``LaunchArguments/Failure`` for a wrong argument list, or
    ///   the error of the file write, of the configuration load or of the
    ///   profile resolution.
    static func main() async throws {
        let arguments = try LaunchArguments(commandLine: CommandLine.arguments)
        let agent = try await makeAgent(arguments)
        let connection = await AgentSideConnection(stream: StdioTransport()) { connection in
            agent.bind(connection: connection)
        }
        _ = await connection.closed
        await agent.waitForConnectionTeardown()
    }

    /// Makes the real agent: writes ``userConfigYAML`` into a user layer
    /// under the state directory, loads the configuration, and resolves the
    /// profile through a router that loads the real model and decodes
    /// greedy.
    ///
    /// - Parameter arguments: The directories of the launch.
    /// - Returns: The agent, with its models loaded.
    /// - Throws: The error of the file write, of the configuration load or of
    ///   the profile resolution.
    private static func makeAgent(_ arguments: LaunchArguments) async throws -> RoutedACPAgent {
        // A custom home keeps the user layer in its synced root and the hook
        // data in its local root, so the agent reads and writes no folder of
        // the real home.
        let home = AgentHome.makeCustom(
            synced: arguments.stateDirectory.appending(path: "user", directoryHint: .isDirectory),
            local: arguments.stateDirectory.appending(path: "local", directoryHint: .isDirectory))
        let recordingsDirectory = arguments.stateDirectory.appending(
            path: "recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home.synced, withIntermediateDirectories: true)
        try userConfigYAML.write(
            to: home.synced.appending(path: ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
        let name = try DotfolderName(agentName)
        let configuration = try ConfigurationLoader(
            settingsFolders: SettingsFolders(name: name, home: home, environment: [:]),
            workingDirectory: arguments.workingDirectory
        ).load().configuration
        let hooks = AgentHooks(dataDirectory: home.hooksDirectory)
        // The loader keeps the shared Hugging Face cache, not the model
        // folder of the custom home, so a run does not download the models
        // again.
        let router = Router(
            recordingsDir: recordingsDirectory,
            loader: LiveModelLoader(),
            samplingMode: .greedy,
            hooks: hooks.dispatcher)
        return try await RoutedACPAgent(
            name: name,
            router: router,
            hooks: hooks,
            configuration: configuration,
            home: home,
            environment: [:])
    }
}

/// The two directories that the test gives the server on its command line.
struct LaunchArguments {
    /// A command line that does not hold exactly the two directories.
    enum Failure: Error, CustomStringConvertible {
        /// The command line held this count of arguments after the
        /// executable path.
        case wrongArgumentCount(Int)

        /// The usage text, with the count that the command line held.
        var description: String {
            switch self {
            case .wrongArgumentCount(let count):
                "usage: live-agent-server <state-directory> <working-directory> (got \(count) arguments)"
            }
        }
    }

    /// The directory that holds the user layer and the recordings of the
    /// agent.
    let stateDirectory: URL

    /// The working directory of the configuration load.
    let workingDirectory: URL

    /// Reads the two directories from a command line.
    ///
    /// - Parameter commandLine: The command line: the executable path, then
    ///   the state directory and the working directory.
    /// - Throws: ``Failure/wrongArgumentCount(_:)`` when the command line
    ///   does not hold exactly two directories after the executable path.
    init(commandLine: [String]) throws {
        let directories = commandLine.dropFirst().map { URL(filePath: $0, directoryHint: .isDirectory) }
        guard let stateDirectory = directories.first,
            let workingDirectory = directories.last,
            directories.count == Self.directoryCount
        else {
            throw Failure.wrongArgumentCount(directories.count)
        }
        self.stateDirectory = stateDirectory
        self.workingDirectory = workingDirectory
    }

    /// The count of directories on the command line.
    private static let directoryCount = 2
}
