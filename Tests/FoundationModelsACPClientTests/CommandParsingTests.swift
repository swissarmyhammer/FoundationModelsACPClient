import ArgumentParser
import Testing

@testable import AcpClientCore

// These tests cover the subcommand tree, the `--` separator and the usage
// errors of `cli-plan.md` §6, and the options of §6.1.
//
// Every test parses in process, with ArgumentParser's `parseAsRoot(_:)`. None
// of them spawns the binary. A spawn would measure the process launcher as
// much as the grammar, and the grammar is what §6 fixes. The three subcommand
// bodies are not written yet, and no test here runs one.
//
// The import is `@testable` for the same reason `PromptSourceTests` uses one:
// the command types are internal to the executable target. Making the whole
// command tree public would widen the surface of a binary that no other module
// links, and it would buy nothing this suite cannot already reach.

/// The `--timeout` values that give the turn no time to run in.
///
/// Zero is a limit that has already passed at the moment the turn starts, and a
/// negative limit passed before that. Neither can end anything but the run
/// itself, so `cli-plan.md` §6.1 has no meaning for either and §9 makes them the
/// usage error.
private let meaninglessTimeoutValues = ["0", "-1"]

@Suite("acp-client command parsing")
struct CommandParsingTests {
    /// The exit code `cli-plan.md` §9 gives a usage error.
    private static let usageErrorExitCode: Int32 = 2

    /// An agent command, for the tests that do not care what it holds.
    private static let agentCommand = ["acp-agent", "acp"]

    /// A one-word agent command, which is the least the separator can carry.
    private static let oneWordAgentCommand = ["a"]

    /// The prompt argument, for the tests that do not care what it holds.
    private static let prompt = "write a haiku"

    /// The path `--cwd` carries in these tests.
    private static let workingDirectory = "/tmp"

    /// The limit `--timeout` carries in these tests.
    ///
    /// The command-line fragment interpolates this same value, so the argument
    /// and the expectation cannot drift apart.
    private static let timeoutSeconds: Double = 30

    /// Every option of §6.1 that all three subcommands take, as the words a
    /// command line carries.
    private static let sharedOptionArguments = [
        "--cwd", workingDirectory,
        "--frames",
        "--timeout", "\(timeoutSeconds)",
        "--verbose",
        "--quiet",
    ]

    /// Parses one argument list as the root command, and returns the
    /// subcommand it selected.
    ///
    /// - Parameters:
    ///   - arguments: The argument list, without the command name.
    ///   - commandType: The subcommand type the list must select.
    /// - Returns: The parsed subcommand.
    /// - Throws: Whatever `parseAsRoot(_:)` throws, or a requirement failure
    ///   when the list selected another subcommand.
    private static func parse<Command: ParsableCommand>(
        _ arguments: [String],
        as commandType: Command.Type
    ) throws -> Command {
        let parsed = try AcpClient.parseAsRoot(arguments)
        return try #require(
            parsed as? Command,
            "\(arguments) must select \(commandType). It selected \(type(of: parsed))."
        )
    }

    /// Parses one subcommand invocation that carries every shared option, and
    /// returns the group it filled in.
    ///
    /// - Parameters:
    ///   - subcommandName: The subcommand to name on the command line.
    ///   - commandType: The subcommand type the name must select.
    /// - Returns: The options group the parse filled in.
    /// - Throws: Whatever ``parse(_:as:)`` throws.
    private static func sharedOptions<Command: ParsableCommand>(
        of subcommandName: String,
        as commandType: Command.Type,
        reading options: (Command) -> SharedOptions
    ) throws -> SharedOptions {
        let arguments =
            [subcommandName] + sharedOptionArguments + ["--"] + agentCommand
        return options(try parse(arguments, as: commandType))
    }

    /// Asserts that one options group holds every value
    /// ``sharedOptionArguments`` sets.
    ///
    /// - Parameter options: The group the parse filled in.
    private static func expectEverySharedOption(_ options: SharedOptions) {
        #expect(options.cwd == workingDirectory)
        #expect(options.frames)
        #expect(options.timeout == timeoutSeconds)
        #expect(options.verbose)
        #expect(options.quiet)
    }

    /// Returns the error one argument list threw, or `nil` when it parsed.
    ///
    /// - Parameter arguments: The argument list, without the command name.
    /// - Returns: The error, or `nil`.
    private static func errorFromParsing(_ arguments: [String]) -> (any Error)? {
        do {
            _ = try AcpClient.parseAsRoot(arguments)
            return nil
        } catch {
            return error
        }
    }

    /// §6: `run` is the default subcommand, so a command line that names no
    /// subcommand is a run.
    ///
    /// The empty argument list is not the case that proves this, and it cannot
    /// be: it selects `run`, and `run` then has no agent command, which §6
    /// makes a usage error. `anEmptyCommandLineIsAUsageError` covers that. So
    /// the selection is read twice here — from the configuration, and from a
    /// command line that names no subcommand and does carry an agent command.
    @Test("run is the default subcommand")
    func runIsTheDefaultSubcommand() throws {
        let declared = try #require(
            AcpClient.configuration.defaultSubcommand,
            "The root command must declare a default subcommand."
        )
        #expect(
            ObjectIdentifier(declared) == ObjectIdentifier(RunCommand.self),
            "The default subcommand must be run. It is \(declared)."
        )

        let command = try Self.parse(["--"] + Self.agentCommand, as: RunCommand.self)

        #expect(command.invocation.agentCommand == Self.agentCommand)
    }

    /// §6: there is no default agent, so an empty command line names none and
    /// is the usage error, exactly as a `run` without the separator is.
    @Test("an empty command line is a usage error")
    func anEmptyCommandLineIsAUsageError() throws {
        let error = try #require(
            Self.errorFromParsing([]),
            "An empty command line must throw: it names no agent command."
        )

        #expect(AcpClient.processExitCode(for: error) == Self.usageErrorExitCode)
    }

    @Test("probe takes the agent command after the separator")
    func probeTakesTheAgentCommand() throws {
        let command = try Self.parse(
            ["probe", "--"] + Self.oneWordAgentCommand,
            as: ProbeCommand.self
        )

        #expect(command.invocation.agentCommand == Self.oneWordAgentCommand)
    }

    @Test("doctor takes the agent command after the separator")
    func doctorTakesTheAgentCommand() throws {
        let command = try Self.parse(
            ["doctor", "--"] + Self.oneWordAgentCommand,
            as: DoctorCommand.self
        )

        #expect(command.invocation.agentCommand == Self.oneWordAgentCommand)
    }

    /// §6: everything after `--` reaches the agent unchanged, its own flags
    /// included, and the prompt before it stays the prompt.
    @Test("the agent flags after the separator reach the agent command unchanged")
    func theAgentKeepsItsOwnFlags() throws {
        let agentCommand = ["npx", "x", "--model", "small"]

        let command = try Self.parse(["run", "p", "--"] + agentCommand, as: RunCommand.self)

        #expect(command.prompt == "p")
        #expect(command.invocation.agentCommand == agentCommand)
    }

    /// §6: the binary never splits a command string into words, so a separator
    /// inside the agent's own arguments is one more word of the agent command
    /// and not a second separator.
    @Test("a separator inside the agent arguments stays part of the agent command")
    func aSecondSeparatorStaysInTheAgentCommand() throws {
        let agentCommand = ["npx", "x", "--", "inner"]

        let command = try Self.parse(["run", "p", "--"] + agentCommand, as: RunCommand.self)

        #expect(command.invocation.agentCommand == agentCommand)
    }

    /// §6: with no `--`, the command is a usage error, and §9 gives a usage
    /// error the code 2. There is no default agent, so an empty agent command
    /// is always an error.
    ///
    /// ArgumentParser's own `exitCode(for:)` answers `EX_USAGE`, which is 64
    /// and not a code §9 uses. It stays the classifier, and
    /// `AcpClient.processExitCode(for:)` is what turns its verdict into the
    /// number of the table.
    @Test("run without the separator is a usage error that exits 2")
    func runWithoutTheSeparatorIsAUsageError() throws {
        let error = try #require(
            Self.errorFromParsing(["run", "p"]),
            "`run p` must throw: it names no agent command."
        )

        #expect(AcpClient.exitCode(for: error) == .validationFailure)
        #expect(AcpClient.processExitCode(for: error) == Self.usageErrorExitCode)
    }

    /// §6.1 gives `--timeout` a number of seconds to run the turn in, and §9
    /// gives a mistake on the command line the code 2. A limit that is not more
    /// than zero seconds gives the turn no time at all, so it can only end the
    /// run it was meant to bound.
    @Test(
        "a --timeout that is not more than zero is a usage error that exits 2",
        arguments: meaninglessTimeoutValues
    )
    func aTimeoutThatIsNotMoreThanZeroIsAUsageError(value: String) throws {
        let error = try #require(
            Self.errorFromParsing(
                ["run", Self.prompt, "--timeout", value, "--"] + Self.agentCommand
            ),
            "`--timeout \(value)` must throw: it gives the turn no time to run in."
        )

        #expect(AcpClient.exitCode(for: error) == .validationFailure)
        #expect(AcpClient.processExitCode(for: error) == Self.usageErrorExitCode)
    }

    @Test("run takes every shared option of section 6.1")
    func runTakesTheSharedOptions() throws {
        let options = try Self.sharedOptions(of: "run", as: RunCommand.self) { $0.options }

        Self.expectEverySharedOption(options)
    }

    @Test("probe takes every shared option of section 6.1")
    func probeTakesTheSharedOptions() throws {
        let options = try Self.sharedOptions(of: "probe", as: ProbeCommand.self) { $0.options }

        Self.expectEverySharedOption(options)
    }

    @Test("doctor takes every shared option of section 6.1")
    func doctorTakesTheSharedOptions() throws {
        let options = try Self.sharedOptions(of: "doctor", as: DoctorCommand.self) { $0.options }

        Self.expectEverySharedOption(options)
    }

    @Test("run rejects --json, which belongs to probe and doctor")
    func runRejectsTheJSONOption() {
        #expect(throws: (any Error).self) {
            _ = try AcpClient.parseAsRoot(["run", Self.prompt, "--json", "--"] + Self.agentCommand)
        }
    }

    @Test("probe takes --json")
    func probeTakesTheJSONOption() throws {
        let command = try Self.parse(
            ["probe", "--json", "--"] + Self.agentCommand,
            as: ProbeCommand.self
        )

        #expect(command.report.json)
    }

    @Test("doctor takes --json")
    func doctorTakesTheJSONOption() throws {
        let command = try Self.parse(
            ["doctor", "--json", "--"] + Self.agentCommand,
            as: DoctorCommand.self
        )

        #expect(command.report.json)
    }

    @Test("the root command names the three subcommands of section 6")
    func theRootNamesEverySubcommand() {
        let subcommands = AcpClient.configuration.subcommands.map { ObjectIdentifier($0) }

        #expect(subcommands.count == 3, "The root command must declare run, probe and doctor.")
        #expect(subcommands.contains(ObjectIdentifier(RunCommand.self)))
        #expect(subcommands.contains(ObjectIdentifier(ProbeCommand.self)))
        #expect(subcommands.contains(ObjectIdentifier(DoctorCommand.self)))
    }
}
