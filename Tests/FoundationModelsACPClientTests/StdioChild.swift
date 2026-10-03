import Darwin

// The children the process tests spawn. They are `/bin/cat`, `/bin/sleep` and
// a `/bin/sh` script, and not an ACP agent: `cat` reads its stdin until end of
// file, `sleep` ignores its stdin, and the script runs `cat` and then `sleep`.
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

    /// Tells whether the process table holds `pid`. A reaped child is gone
    /// from the table; a live child and a zombie are both in it.
    ///
    /// - Parameter pid: The pid to look for.
    /// - Returns: `true` when `kill(pid, 0)` finds the process.
    static func isInProcessTable(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
