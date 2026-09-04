import ArgumentParser
import Darwin
import Foundation

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
    /// The exit code `cli-plan.md` §9 gives a usage error.
    ///
    /// ArgumentParser's own `ExitCode.validationFailure` is `EX_USAGE`, which
    /// is 64. §9 does not use 64: it pins a usage error at 2, so that this
    /// binary and `acp-agent` report the same code for the same mistake.
    static let usageExitCode: Int32 = 2

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
    static let configuration = CommandConfiguration(
        commandName: "acp-client",
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
    /// `EX_USAGE` disagree there and nowhere else that this milestone reaches.
    ///
    /// The rest of the §9 table — 3 for a refusal, 4 for a cancellation, 5 for
    /// `doctor` warnings, and 124 for a timeout — arrives with the runs that
    /// can produce those outcomes.
    ///
    /// - Parameter error: The error the run ended with.
    /// - Returns: The code to exit the process with.
    static func processExitCode(for error: any Error) -> Int32 {
        let parserExitCode = exitCode(for: error)
        guard parserExitCode == .validationFailure else { return parserExitCode.rawValue }
        return usageExitCode
    }

    /// Runs the binary, and exits with the code `cli-plan.md` §9 gives the
    /// outcome.
    ///
    /// This stands in for ArgumentParser's own `main()` for one reason: that
    /// one ends a usage error with `EX_USAGE`, and §9 ends it with 2. The text
    /// is unchanged — `fullMessage(for:)` is the same message
    /// `exit(withError:)` would have printed, and it still goes to stderr,
    /// leaving stdout empty as §8 requires. Every other outcome, `--help` and
    /// `--version` included, still goes through `exit(withError:)`.
    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            guard exitCode(for: error) == .validationFailure else { exit(withError: error) }
            let message = fullMessage(for: error)
            if !message.isEmpty {
                FileHandle.standardError.write(Data("\(message)\n".utf8))
            }
            Darwin.exit(processExitCode(for: error))
        }
    }
}
