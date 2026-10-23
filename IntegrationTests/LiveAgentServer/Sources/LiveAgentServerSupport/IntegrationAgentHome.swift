import Foundation
import FoundationModelsACPAgent

/// The home of the agent of a test server, under the state directory that
/// the test gives.
public enum IntegrationAgentHome {
    /// The `tools` section of the user-layer `config.yaml` of each test
    /// server. The skills marketplace list is empty and the code context is
    /// off, so the agent does not use the network and does not index the
    /// workspace.
    public static let offlineToolsYAML = """
        tools:
          codeContext: false
          skills:
            marketplaces: []
        """

    /// Makes a custom home under `stateDirectory`, and writes the user-layer
    /// `config.yaml` of the agent into it.
    ///
    /// A custom home keeps the user layer in its synced root and the hook
    /// data in its local root, so the agent reads and writes no folder of
    /// the real home.
    ///
    /// - Parameters:
    ///   - stateDirectory: The state directory of the launch.
    ///   - userConfigYAML: The text of the user-layer `config.yaml`.
    /// - Returns: The home.
    /// - Throws: The error of the directory creation or of the file write.
    public static func make(under stateDirectory: URL, userConfigYAML: String) throws -> AgentHome {
        let home = AgentHome.makeCustom(
            synced: stateDirectory.appending(path: "user", directoryHint: .isDirectory),
            local: stateDirectory.appending(path: "local", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: home.synced, withIntermediateDirectories: true)
        try userConfigYAML.write(
            to: home.synced.appending(path: ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
        return home
    }
}
