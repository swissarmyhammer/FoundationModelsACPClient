// The `--timeout` option of `cli-plan.md` §6.1, as the words a command line
// carries.
//
// Two suites drive the option and they drive it for opposite reasons.
// `TimeoutTests` proves that `run` OBEYS it: the limit ends the turn, the run
// exits 124, and the agent is reaped. `DoctorCommandTests` proves that `doctor`
// IGNORES it: a diagnosis runs no turn, so it keeps a limit of its own whatever
// the option says. Both readings rest on one spelling of the option, so the
// spelling lives here once.

/// The option of `cli-plan.md` §6.1 that bounds the turn.
let timeoutOptionName = "--timeout"

/// A `--timeout` value that is legal, and far under every interval a run needs.
///
/// §6.1 refuses only a limit that is not more than zero seconds, so one
/// millisecond parses. It is far shorter than a spawn, a handshake and a
/// teardown, so a subcommand that wrongly took this option as its OWN limit
/// would collapse every wait it makes and report a failure the agent does not
/// have. That is what makes it the discriminating value for `doctor`.
let collapsingTimeoutValue = "0.001"

/// Renders the `--timeout` option as the two words a command line carries.
///
/// - Parameter value: The value to give the option, as it is typed.
/// - Returns: The option and its value.
func timeoutOption(_ value: String) -> [String] {
    [timeoutOptionName, value]
}
