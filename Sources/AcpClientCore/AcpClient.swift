import ArgumentParser
import Darwin
import Foundation

/// The `acp-client` command-line client for any ACP v2 agent.
///
/// The binary writes no parser of its own: `AsyncParsableCommand` gives it
/// `--help`, `--version`, the subcommand tree and the usage errors
/// (`cli-plan.md` §4).
///
/// This type lives in the `AcpClientCore` library and not in the `acp-client`
/// executable target, because SwiftPM publishes no importable module for an
/// executable product across a package boundary. The `IntegrationTests`
/// package drives this code directly, so the code has to sit in a library
/// product. ``AcpClientMain`` in `Sources/acp-client/` is the `@main` type
/// that calls ``run(_:)``. That target holds it and the telemetry bootstrap
/// alone.
///
/// This is the one seam the executable target reaches across, so it is the one
/// type of the command tree that is `public`. ``RunCommand``, ``ProbeCommand``
/// and ``DoctorCommand`` stay internal: the unit suite reaches them with
/// `@testable import`, and nothing outside this module names them.
public struct AcpClient: AsyncParsableCommand {
    /// Creates the root command.
    ///
    /// `ParsableCommand` needs a public initializer on a public conforming
    /// type. The parser is what calls it.
    public init() {}

    /// The name of this binary on the command line.
    ///
    /// One constant, so the usage text the parser prints and the name
    /// ``AgentSession/initialize()`` reports to the agent can never disagree
    /// about what this binary calls itself.
    static let commandName = "acp-client"

    /// The command-line configuration of the root command.
    ///
    /// `version:` is what answers `--version`, so the flag can report nothing
    /// but ``AcpClientVersion/current``.
    ///
    /// `defaultSubcommand:` makes `acp-client -- <agent-command>` a run, which
    /// is the shape `cli-plan.md` §6 gives the common case. It does not make an
    /// empty command line a run: `run` still needs an agent command after the
    /// `--` separator, and without one the binary prints the usage to stderr
    /// and exits 2.
    public static let configuration = CommandConfiguration(
        commandName: Self.commandName,
        abstract: "Runs one turn against any ACP v2 agent and prints the answer.",
        version: AcpClientVersion.current,
        subcommands: [RunCommand.self, ProbeCommand.self, DoctorCommand.self],
        defaultSubcommand: RunCommand.self
    )

    /// Returns the process exit code for one error thrown out of the parser or
    /// out of a subcommand body.
    ///
    /// ArgumentParser stays the classifier: `exitCode(for:)` is what decides
    /// whether an error is a usage mistake, a clean exit, or a failure. Only
    /// the number changes, and only for the usage class, because §9 and
    /// `EX_USAGE` disagree there and nowhere else the parser reaches.
    ///
    /// The number comes from ``AcpClientExitCode``, which owns the whole §9
    /// table. This function is the parser's half of it: a `--help` and a
    /// `--version` are clean exits ArgumentParser already numbers, so its
    /// answer stands for every class but the usage one. The outcomes a run
    /// produces — a refusal, a cancellation, a `doctor` verdict, a timeout —
    /// reach the table through ``AcpClientExitCode/forError(_:)`` and its
    /// siblings instead.
    ///
    /// - Parameter error: The error the run ended with.
    /// - Returns: The code to exit the process with.
    static func processExitCode(for error: any Error) -> Int32 {
        let parserExitCode = exitCode(for: error)
        guard parserExitCode == .validationFailure else { return parserExitCode.rawValue }
        return AcpClientExitCode.usage.rawValue
    }

    /// Runs the binary, and exits with the code `cli-plan.md` §9 gives the
    /// outcome.
    ///
    /// This stands in for ArgumentParser's own `main()` for one reason: that
    /// one ends a usage error with `EX_USAGE`, and §9 ends it with 2.
    /// ``run(_:)`` does the work and gives the code back. This function only
    /// ends the process with that code.
    public static func main() async {
        Darwin.exit(await run())
    }

    /// Runs the binary, and returns the code `cli-plan.md` §9 gives the
    /// outcome. It does not end the process.
    ///
    /// The caller ends the process with the returned code. So the caller can
    /// do more work first: the `acp-client` executable flushes the
    /// OpenTelemetry exporters before it exits.
    ///
    /// The text that this function writes is the text that
    /// `exit(withError:)` of ArgumentParser writes, at the same destination.
    /// See ``report(_:)``.
    ///
    /// - Parameter arguments: The command-line arguments without the name of
    ///   the binary, or `nil` to read the arguments of this process.
    /// - Returns: The code to exit the process with.
    public static func run(_ arguments: [String]? = nil) async -> Int32 {
        do {
            var command = try parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            return AcpClientExitCode.success.rawValue
        } catch {
            report(error)
            return processExitCode(for: error)
        }
    }

    /// Writes the message of the error that ended a run, as
    /// `exit(withError:)` of ArgumentParser writes it.
    ///
    /// ArgumentParser gives the success code only to a clean exit: `--help`,
    /// `--version` and a `CleanExit`. The message of a clean exit goes to
    /// standard output, where a user can pipe the help text. Each other
    /// message goes to standard error, so that standard output stays empty
    /// (`cli-plan.md` §8). An error with no message, such as an `ExitCode`
    /// from a subcommand, writes nothing.
    ///
    /// - Parameter error: The error the run ended with.
    private static func report(_ error: any Error) {
        let message = fullMessage(for: error)
        guard !message.isEmpty else { return }
        let destination: FileHandle =
            exitCode(for: error) == .success ? .standardOutput : .standardError
        destination.write(Data("\(message)\n".utf8))
    }
}
