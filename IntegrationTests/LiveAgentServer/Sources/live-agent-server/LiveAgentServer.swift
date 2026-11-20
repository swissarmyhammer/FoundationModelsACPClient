import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsExtras
import FoundationModelsRouter
import LiveAgentServerSupport

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

    /// The model of the `flash` slot: a model that is smaller than
    /// ``standardModel``, so that the slot costs little memory. The
    /// `agents-demo` example of FoundationModelsAgents uses the same pair,
    /// and the CI runner keeps both models in its cache.
    static let flashModel = "mlx-community/Qwen3-1.7B-4bit"

    /// The model of the `embedding` slot. It is the smallest embedding model
    /// that FoundationModelsACPAgent uses (about 0.31 GB): each shipped
    /// profile and the `EmbeddingModelTests` fixture name it.
    static let embeddingModel = "erjigit17/embeddinggemma-300m-ane-coreml"

    /// The model of the `decision` slot: the `h2o-lightning-4b` GGUF of the
    /// shipped profiles, at its pinned revision. FoundationModelsACPAgent
    /// tests no smaller decision model.
    static let decisionModel =
        "h2oai/h2o-lightning-4b-gguf/h2o-lightning-4b-Q4_K_M.gguf@61f8d8b7a8c2d84426d0d143ca187f65d235934b"

    /// The context of the `decision` slot, in tokens: the value of the
    /// shipped profiles.
    static let decisionContext = 16_384

    /// The name of the test profile: the name of its file in the user layer.
    static let profileName = "integration"

    /// The user-layer profile file of the test profile, in the format of
    /// Router's `ProfileDefinition`.
    ///
    /// The file names each model slot. A key that a profile file leaves out
    /// takes its value from the shipped profile `large`, and the models of
    /// `large` do not fit the memory of a CI runner. So each slot names a
    /// small model, and the profile fits a CI runner.
    static let profileYAML = """
        description: Small models for the integration test of FoundationModelsACPClient.
        standard: ["\(standardModel)"]
        flash: ["\(flashModel)"]
        embedding: ["\(embeddingModel)"]
        decision: ["\(decisionModel)"]
        decisionContext: \(decisionContext)
        """

    /// The user-layer `config.yaml` of the agent: the offline tools section
    /// of each test server, and the name of the test profile.
    static let userConfigYAML = """
        \(IntegrationAgentHome.offlineToolsYAML)
        profile: \(profileName)
        """

    /// Makes the agent, serves it on stdin and stdout, and returns when the
    /// connection closed and the agent finished its teardown.
    ///
    /// A start error (`LaunchArguments.Failure` for a wrong argument list, or
    /// the error of the file write, of the configuration load or of the
    /// profile resolution) does not get out of this function: `ServerStart`
    /// writes the reason to stderr and exits with status 1.
    static func main() async {
        let agent = await ServerStart.make {
            try await makeAgent(LaunchArguments(commandLine: CommandLine.arguments))
        }
        let connection = await AgentSideConnection(stream: StdioTransport()) { connection in
            agent.bind(connection: connection)
        }
        _ = await connection.closed
        await agent.waitForConnectionTeardown()
    }

    /// Makes the real agent: writes ``userConfigYAML`` and ``profileYAML``
    /// into a user layer under the state directory, loads the configuration, and resolves the
    /// profile through a router that loads the real model and decodes
    /// greedy.
    ///
    /// - Parameter arguments: The directories of the launch.
    /// - Returns: The agent, with its models loaded.
    /// - Throws: The error of the file write, of the configuration load or of
    ///   the profile resolution.
    private static func makeAgent(_ arguments: LaunchArguments) async throws -> RoutedACPAgent {
        let home = try IntegrationAgentHome.make(
            under: arguments.stateDirectory, userConfigYAML: userConfigYAML,
            profiles: [profileName: profileYAML])
        let recordingsDirectory = arguments.stateDirectory.appending(
            path: "recordings", directoryHint: .isDirectory)
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
            mode: .open,
            environment: [:])
    }
}
