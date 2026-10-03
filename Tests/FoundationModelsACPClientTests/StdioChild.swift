import Darwin

// The children the process tests spawn. They are `/bin/cat`, `/bin/sleep` and
// two `/bin/sh` scripts, and not an ACP agent: `cat` reads its stdin until end
// of file, `sleep` ignores its stdin, one script runs `cat` and then `sleep`,
// and the other tells whether the child holds one descriptor.
// The tests that spawn a real foreign agent over stdio live in the nested
// `IntegrationTests` package.

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

    /// Tells whether the process table holds `pid`. A reaped child is gone
    /// from the table; a live child and a zombie are both in it.
    ///
    /// - Parameter pid: The pid to look for.
    /// - Returns: `true` when `kill(pid, 0)` finds the process.
    static func isInProcessTable(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
