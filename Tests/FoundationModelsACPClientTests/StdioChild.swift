import Darwin

// The children the process tests spawn. They are `/bin/cat` and `/bin/sleep`,
// and not an ACP agent: `cat` reads its stdin until end of file, and `sleep`
// ignores its stdin. The tests that spawn a real foreign agent over stdio live
// in the nested `IntegrationTests` package.

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

    /// Tells whether the process table holds `pid`. A reaped child is gone
    /// from the table; a live child and a zombie are both in it.
    ///
    /// - Parameter pid: The pid to look for.
    /// - Returns: `true` when `kill(pid, 0)` finds the process.
    static func isInProcessTable(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
