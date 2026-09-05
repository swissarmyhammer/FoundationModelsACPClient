// The exit code table of `cli-plan.md` §9, as this suite reads it back off a
// finished process.
//
// The numbers are spelled here rather than read from the binary's
// `AcpClientExitCode`: SwiftPM builds an executable product for this test
// bundle to spawn, and it publishes no module to another package. The unit
// suite's `ExitCodeTests` pins that table against the same §9 rows, so a
// renumbering fails there and here alike.
//
// One copy for the whole suite, and not one per file. Two suites that disagreed
// about what 124 means would each pass while the binary served neither.

/// The exit codes of `cli-plan.md` §9 the integration suites assert.
enum SectionNineExitCode {
    /// A turn that ended. `cli-plan.md` §9, row 0.
    static let success: Int32 = 0

    /// A spawn, protocol or I/O error. `cli-plan.md` §9, row 1.
    static let failure: Int32 = 1

    /// A mistake on the command line. `cli-plan.md` §9, row 2.
    static let usage: Int32 = 2

    /// The agent refused to continue the turn. `cli-plan.md` §9, row 3.
    static let refusal: Int32 = 3

    /// The turn was cancelled. `cli-plan.md` §9, row 4.
    static let cancelled: Int32 = 4

    /// The run reached the limit `--timeout` gave it. `cli-plan.md` §9, row 124.
    ///
    /// 124 is the `timeout(1)` convention, so a script that already reads that
    /// number reads this binary with no change.
    static let timeout: Int32 = 124
}
