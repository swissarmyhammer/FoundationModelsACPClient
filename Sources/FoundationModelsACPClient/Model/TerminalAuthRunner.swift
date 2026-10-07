/// Runs the agent program in an interactive terminal, for a `terminal` auth
/// method of the agent.
///
/// The host gives a runner to ``ConnectionModel/loginWithTerminal(_:runner:)``.
/// The model does not know the agent command: the host made the transport of
/// the connection. Thus the host owns the run, and the model owns the auth
/// state.
///
/// The host has these duties:
///
/// - Run the same agent program with the same base launch configuration as
///   the ACP connection. Append `arguments` to the arguments of that
///   command, and apply `environment` over the same-named variables of the
///   launch environment.
/// - Run the program in an interactive terminal, so that the user can type
///   into it. A process on pipes, as ``AgentProcess`` makes, is not
///   sufficient.
/// - Send `capabilities.auth.terminal` in the `initialize` request only when
///   the host can do this run. Without it, the agent lists no `terminal`
///   method, and the model refuses each terminal login.
public protocol TerminalAuthRunner: Sendable {
    /// Runs the agent program in an interactive terminal, and waits until it
    /// ends.
    ///
    /// - Parameters:
    ///   - arguments: The arguments to append to the agent command.
    ///   - environment: The variables to apply over the launch environment,
    ///     keyed by name.
    /// - Returns: The exit status of the process, or `nil` when the process
    ///   ended with no exit status, for example because of a signal.
    /// - Throws: An error when the program did not start.
    func runTerminalAuth(arguments: [String], environment: [String: String]) async throws -> Int32?
}
