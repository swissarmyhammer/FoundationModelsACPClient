import ArgumentParser

/// The `acp-client` command-line client for any ACP v2 agent.
///
/// The binary writes no parser of its own: `AsyncParsableCommand` gives it
/// `--help`, `--version`, the subcommand tree and the usage errors
/// (`cli-plan.md` §4).
///
/// This type lives in `AcpClient.swift` and not in `main.swift` on purpose. A
/// target whose sources hold top-level code cannot be imported, and the unit
/// suite imports this target.
@main
struct AcpClient: AsyncParsableCommand {
    /// The command-line configuration of the root command.
    static let configuration = CommandConfiguration(
        commandName: "acp-client",
        abstract: "Runs one turn against any ACP v2 agent and prints the answer.",
        version: AcpClientVersion.current
    )
}
