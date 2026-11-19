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

    /// The folder of the profile files in a layer, as the README of
    /// FoundationModelsACPAgent ("Profile files") gives it:
    /// `<layer>/profiles/<name>.yaml`. The type of the agent that holds this
    /// name is internal, so this server names the folder itself.
    public static let profilesFolderName = "profiles"

    /// The extension of a profile file. The name of the file without this
    /// extension is the name of the profile.
    public static let profileFileExtension = "yaml"

    /// Makes a custom home under `stateDirectory`, and writes the user-layer
    /// `config.yaml` and the user-layer profile files of the agent into it.
    ///
    /// A custom home keeps the user layer in its synced root and the hook
    /// data in its local root, so the agent reads and writes no folder of
    /// the real home. The projects folder is the
    /// `AgentHome.projectsFolderName` folder of the synced root, as the
    /// `acp-agent` executable of FoundationModelsACPAgent puts it.
    ///
    /// - Parameters:
    ///   - stateDirectory: The state directory of the launch.
    ///   - userConfigYAML: The text of the user-layer `config.yaml`.
    ///   - profiles: The text of each user-layer profile file, by the name of
    ///     its profile. The default is no profile file.
    /// - Returns: The home.
    /// - Throws: The error of the directory creation or of a file write.
    public static func make(
        under stateDirectory: URL, userConfigYAML: String, profiles: [String: String] = [:]
    ) throws -> AgentHome {
        let synced = stateDirectory.appending(path: "user", directoryHint: .isDirectory)
        let home = AgentHome.makeCustom(
            synced: synced,
            local: stateDirectory.appending(path: "local", directoryHint: .isDirectory),
            projects: synced.appending(path: AgentHome.projectsFolderName, directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: home.synced, withIntermediateDirectories: true)
        try userConfigYAML.write(
            to: home.synced.appending(path: ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
        try writeProfiles(profiles, into: home.synced)
        return home
    }

    /// Writes each profile file into the profiles folder of a layer.
    ///
    /// - Parameters:
    ///   - profiles: The text of each profile file, by the name of its
    ///     profile.
    ///   - layerRoot: The root folder of the layer: the folder of its
    ///     `config.yaml`.
    /// - Throws: The error of the directory creation or of a file write.
    private static func writeProfiles(_ profiles: [String: String], into layerRoot: URL) throws {
        guard !profiles.isEmpty else { return }
        let folder = layerRoot.appending(path: profilesFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, yaml) in profiles {
            try yaml.write(
                to: folder.appending(path: "\(name).\(profileFileExtension)"),
                atomically: true, encoding: .utf8)
        }
    }
}
