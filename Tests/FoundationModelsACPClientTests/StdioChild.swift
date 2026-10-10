import Darwin
import Foundation

@testable import FoundationModelsACPClient

// The children the process tests spawn. They are `/bin/cat`, `/bin/sleep`,
// `/usr/bin/env`, `/bin/pwd` and three `/bin/sh` scripts, and not an ACP
// agent: `cat` reads its stdin until end of file, `sleep` ignores its stdin,
// `env` writes its environment, `pwd` writes its working directory, one script
// runs `cat` and then `sleep`, one tells whether the child holds one
// descriptor, and one exits at once with a given status.

/// The commands of the children the process tests spawn, and the test of the
/// process table those tests share.
enum StdioChild {
    /// The command for a child that reads its stdin until end of file.
    static let readingCommand = "/bin/cat"

    /// The command for a child that ignores its stdin.
    static let idleCommand = "/bin/sleep"

    /// The number of seconds the idle child sleeps. It is long enough that
    /// the child outlives the test unless the test kills it.
    static let idleSeconds = "300"

    /// The command for a child that reads its stdin until end of file and
    /// exits a fixed time after it. It runs ``slowReadingScript``.
    static let slowReadingCommand = "/bin/sh"

    /// The arguments that make ``slowReadingCommand`` read its stdin until
    /// end of file, and then sleep for half a second before it exits. The
    /// late exit is a deterministic model of a child that a loaded machine
    /// schedules late.
    static let slowReadingScript = ["-c", "/bin/cat; /bin/sleep 0.5"]

    /// The command for a child that tells whether it holds one descriptor. It
    /// runs the script of ``descriptorProbeArguments(for:)``.
    static let descriptorProbeCommand = "/bin/sh"

    /// The word the descriptor probe writes on its stdout when it holds the
    /// descriptor.
    static let descriptorOpenAnswer = "open"

    /// The word the descriptor probe writes on its stdout when it does not
    /// hold the descriptor.
    static let descriptorClosedAnswer = "closed"

    /// The arguments that make ``descriptorProbeCommand`` write
    /// ``descriptorOpenAnswer`` when it holds `descriptor`, or
    /// ``descriptorClosedAnswer`` when it does not, and then exit.
    ///
    /// `/dev/fd/N` exists only while the process that reads it holds the
    /// descriptor `N`, so the test of the shell answers for the child itself.
    ///
    /// - Parameter descriptor: The descriptor number to look for.
    /// - Returns: The arguments for ``descriptorProbeCommand``.
    static func descriptorProbeArguments(for descriptor: Int32) -> [String] {
        let script =
            "if [ -e \"/dev/fd/$1\" ]; then printf \(descriptorOpenAnswer); "
            + "else printf \(descriptorClosedAnswer); fi"
        return ["-c", script, descriptorProbeCommand, String(descriptor)]
    }

    /// The command for a child that writes its whole environment on its
    /// stdout, one `NAME=value` line for each variable, and then exits.
    static let environmentPrinterCommand = "/usr/bin/env"

    /// The command for a child that writes its working directory on its
    /// stdout, and then exits. It runs with ``directoryPrinterArguments``.
    static let directoryPrinterCommand = "/bin/pwd"

    /// The arguments that make ``directoryPrinterCommand`` write the physical
    /// path, with each symbolic link resolved.
    static let directoryPrinterArguments = ["-P"]

    /// The command for a child that exits at once with a given status. It
    /// runs the script of ``exitingArguments(status:)``.
    static let exitingCommand = "/bin/sh"

    /// The arguments that make ``exitingCommand`` exit with `status`.
    ///
    /// - Parameter status: The exit status of the child.
    /// - Returns: The arguments for ``exitingCommand``.
    static func exitingArguments(status: Int32) -> [String] {
        ["-c", "exit \(status)"]
    }

    /// Tells whether the process table holds `pid`. A reaped child is gone
    /// from the table; a live child and a zombie are both in it.
    ///
    /// - Parameter pid: The pid to look for.
    /// - Returns: `true` when `kill(pid, 0)` finds the process.
    static func isInProcessTable(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Reads the stdout of a child until it ends, and decodes it as UTF-8.
    ///
    /// - Parameter child: The spawned child to read.
    /// - Returns: The whole stdout of the child, or `nil` when the read failed
    ///   or did not end in time.
    static func wholeStandardOutput(of child: AgentProcess) async -> String? {
        let bytes = child.transport.bytes
        return await outcome { () async -> String? in
            do {
                let answer = try await bytes.reduce(into: Data()) { data, chunk in data.append(chunk) }
                return String(decoding: answer, as: UTF8.self)
            } catch {
                return nil
            }
        } ?? nil
    }
}
