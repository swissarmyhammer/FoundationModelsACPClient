import Foundation
import Testing

// These tests drive the real `acp-client` binary and assert the subcommand tree
// of `cli-plan.md` §6: the three subcommands, the required `--` separator, and
// the two flags that print and exit.
//
// The claims here are about FILE DESCRIPTORS and the PROCESS exit code, and
// that is why they stand in this package. The unit suite's `CommandParsingTests`
// parses the same command lines in process, and it can see what the parser
// throws; it cannot see which descriptor ArgumentParser then wrote to, nor the
// number the process finally exited with. §6 promises the usage text goes to
// stderr with stdout left EMPTY, and §9 owes that run the code 2. Only a run of
// the built binary, with both descriptors captured from outside it, measures
// either one.
//
// Nothing here can import the binary's own types: SwiftPM builds an executable
// product for this test bundle to spawn, and it publishes no module to another
// package. So the sentence the usage error carries is spelled again below,
// against the same section of `cli-plan.md` the unit suite pins the binary to.

/// The number of minutes this file's suite allows itself.
///
/// Every test here spawns the binary, so a loaded machine must not fail a suite
/// that is only slow. The bound each test really rests on is
/// ``TransportTestDeadline/limit``; this one is the backstop that ends a wedged
/// run rather than holding the package open.
private let subcommandTreeSuiteTimeLimitMinutes = 5

/// The prompt the `run` case puts on the command line.
///
/// `run` takes a prompt argument, and this case gives it one so that the ONLY
/// mistake left on the line is the missing separator. With no prompt the run
/// would carry two mistakes at once, and the test could not say which one the
/// binary reported.
private let subcommandTreePrompt = "write a haiku"

/// The sentence the missing-agent-command error of `cli-plan.md` §6 carries.
///
/// Spelled here rather than read from the binary's `AgentInvocation`, which this
/// package cannot import. It is asserted, and not only the exit code, because
/// §6 asks the binary to say WHY there is no default agent: a bare "missing
/// expected argument" from the parser would exit 2 as well and tell the reader
/// nothing.
private let noDefaultAgentSentence = "There is no default agent."

/// One subcommand of the tree `cli-plan.md` §6 gives the binary.
///
/// The three share one grammar — §6 gives them one — so the required separator
/// is one rule, and this suite proves it on all three. A rule proven on `run`
/// alone would leave `probe` and `doctor` free to take a default agent.
enum ClientSubcommand: CaseIterable, Sendable {
    /// `run`, the default subcommand.
    case run

    /// `probe`.
    case probe

    /// `doctor`.
    case doctor

    /// The subcommand's name on the command line.
    var name: String {
        switch self {
        case .run:
            runSubcommandName
        case .probe:
            probeSubcommandName
        case .doctor:
            doctorSubcommandName
        }
    }

    /// The whole command line: this subcommand, and no agent command at all.
    ///
    /// `run` carries its prompt argument, so the missing separator is the one
    /// mistake on the line. The other two take no positional argument of their
    /// own, so the name alone is already a complete invocation but for the
    /// agent.
    var argumentsWithoutSeparator: [String] {
        switch self {
        case .run:
            [name, subcommandTreePrompt]
        case .probe, .doctor:
            [name]
        }
    }
}

/// The subcommand tree of `cli-plan.md` §6 at the process level: what each
/// stream carries, and what the process exits with.
///
/// Serialized and time-limited, in the same way as every other suite in this
/// package: each test here spawns a real process.
@Suite(
    "acp-client subcommand tree",
    .serialized,
    .timeLimit(.minutes(subcommandTreeSuiteTimeLimitMinutes))
)
struct SubcommandTreeTests {
    @Test(
        "a subcommand with no separator exits 2, leaves stdout empty, and says why",
        arguments: ClientSubcommand.allCases
    )
    func aSubcommandWithNoSeparatorIsAUsageError(
        subcommand: ClientSubcommand
    ) async throws {
        let result = try await runAcpClient(subcommand.argumentsWithoutSeparator)

        #expect(result.exitCode == SectionNineExitCode.usage)
        // §6 leaves stdout to the answer even when the run never starts one, so
        // a usage text that reached descriptor 1 would break a caller that
        // reads stdout as data.
        #expect(
            result.standardOutput.isEmpty,
            "stdout was \(result.standardOutput.count) bytes: \"\(text(result.standardOutput))\""
        )
        let reported = text(result.standardError)
        #expect(reported.contains(noDefaultAgentSentence), "stderr was \"\(reported)\"")
    }

    @Test("--help prints the usage to stdout, names the three subcommands, and exits 0")
    func theHelpFlagPrintsTheUsageToStandardOutput() async throws {
        let result = try await runAcpClient(["--help"])

        // §6 gives `--help` the opposite descriptor from the usage ERROR above:
        // the text the user ASKED for is the output of that run, so it goes to
        // stdout and stderr stays empty.
        #expect(result.exitCode == SectionNineExitCode.success)
        let printed = text(result.standardOutput)
        for subcommand in ClientSubcommand.allCases {
            #expect(printed.contains(subcommand.name), "stdout was \"\(printed)\"")
        }
        #expect(
            result.standardError.isEmpty,
            "stderr was \"\(text(result.standardError))\""
        )
    }
}
