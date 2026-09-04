// `PromptSource` — the four-row prompt-source table of `cli-plan.md` §7, as
// one value that stands apart from the command types.
//
// It is a separate value for a testing reason. Two of the four rows turn on
// whether standard input is a terminal, and a test process cannot make its own
// standard input a terminal. So both readings of standard input — whether it
// is a terminal, and what it holds — are injected closures, and every row is
// then reachable from a unit test that touches no real descriptor.

import Darwin
import Foundation

/// A failure while resolving where the prompt of one turn comes from.
enum PromptSourceError: Error, Equatable, CustomStringConvertible {
    /// The command line carried no prompt argument, and standard input is a
    /// terminal, so there is nothing to read (`cli-plan.md` §7, row 3).
    ///
    /// The caller turns this into the usage text on stderr and exit code 2.
    case noPromptAndStdinIsATerminal

    /// A human-readable description of this error.
    var description: String {
        switch self {
        case .noPromptAndStdinIsATerminal:
            return """
                No prompt was given, and standard input is a terminal. \
                Give the prompt as an argument, pipe it in, or pass \
                "\(PromptSource.standardInputArgument)" to read it from the terminal.
                """
        }
    }
}

/// Where the prompt of one turn comes from (`cli-plan.md` §7).
///
/// The standard input this value reads is **this binary's own** standard
/// input. The agent's standard input is a different descriptor: a pipe that
/// `AgentProcess` owns and writes the ndJSON request stream into. The two are
/// never the same descriptor, and neither may be pointed at the other — a
/// share would send the user's prompt bytes into the protocol stream, or the
/// protocol stream into the prompt.
struct PromptSource: Sendable {
    /// The prompt argument that names standard input rather than a prompt
    /// (`cli-plan.md` §7, row 4).
    static let standardInputArgument = "-"

    /// Answers whether this binary's own standard input is a terminal.
    let isStandardInputATerminal: @Sendable () -> Bool

    /// Reads this binary's own standard input to its end.
    let readStandardInput: @Sendable () throws -> String

    /// Creates a prompt source over two readings of standard input.
    ///
    /// Neither reading happens here. Each default is a closure, which
    /// ``prompt(from:)`` calls on the rows that need it and never on the rows
    /// that do not, so construction reads no global state at all and a test
    /// that injects both closures never touches the real standard input.
    ///
    /// - Parameters:
    ///   - isStandardInputATerminal: Answers whether standard input is a
    ///     terminal. The default asks the C library.
    ///   - readStandardInput: Reads standard input to its end. The default
    ///     reads this binary's own standard input.
    init(
        isStandardInputATerminal: @escaping @Sendable () -> Bool = { Self.standardInputIsATerminal() },
        readStandardInput: @escaping @Sendable () throws -> String = { try Self.readStandardInputToEndOfFile() }
    ) {
        self.isStandardInputATerminal = isStandardInputATerminal
        self.readStandardInput = readStandardInput
    }

    /// Returns the prompt for this run, from the command line or from
    /// standard input.
    ///
    /// The four cases are the four rows of `cli-plan.md` §7, in the order the
    /// table gives them.
    ///
    /// - Parameter argument: The prompt argument the command line carried, or
    ///   `nil` when it carried none.
    /// - Returns: The prompt text, verbatim in every case: an argument is the
    ///   prompt as given, and a read of standard input is trimmed of nothing
    ///   and gains no newline.
    /// - Throws: ``PromptSourceError/noPromptAndStdinIsATerminal`` when there
    ///   is no argument and standard input is a terminal, or whatever the
    ///   read of standard input throws.
    func prompt(from argument: String?) throws -> String {
        guard let argument else {
            guard !isStandardInputATerminal() else {
                throw PromptSourceError.noPromptAndStdinIsATerminal
            }
            return try readStandardInput()
        }
        guard argument != Self.standardInputArgument else {
            return try readStandardInput()
        }
        return argument
    }

    /// Answers whether this binary's own standard input is a terminal.
    ///
    /// - Returns: `true` when file descriptor 0 is a terminal, and `false`
    ///   when it is a pipe, a file, or anything else.
    static func standardInputIsATerminal() -> Bool {
        isatty(STDIN_FILENO) == 1
    }

    /// Reads this binary's own standard input to its end.
    ///
    /// - Returns: Every byte standard input held, decoded as UTF-8 and
    ///   otherwise unchanged. Standard input that was already at its end
    ///   gives the empty string.
    /// - Throws: Whatever `FileHandle.readToEnd()` throws.
    static func readStandardInputToEndOfFile() throws -> String {
        guard let data = try FileHandle.standardInput.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
