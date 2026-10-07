import FoundationModelsACP

// The terminal auth part of `ConnectionModel`: the run of a `terminal` auth
// method of the agent, through a runner that the host gives.
//
// ACP v2 authentication gives these rules for a `terminal` method:
//
// - The client runs the configured agent program again, as a separate
//   interactive process, with the `args` of the method appended and its `env`
//   applied over the launch environment.
// - Exit status zero is success. Another status, an end with no exit status,
//   and a cancel are failures.
// - The client must not send `auth/login` for a terminal method.
// - A successful run does not authenticate the open connection. The client
//   must connect again, send `initialize` again, and then retry the
//   operation that needed the login.
// - The agent lists a terminal method only when the client sent
//   `capabilities.auth.terminal` in `initialize`.
//
// The model does not know the agent command, because the host made the
// transport. Thus the host runs the process through `TerminalAuthRunner`, and
// the host makes the new connection. The model owns the auth state: it
// records `reconnectRequired` after a successful run, keeps the method across
// `connect(over:logger:bufferLimits:client:)`, and gives `authenticated` in
// the next `initialize`. The model does not retry the operation that needed
// the login; the host retries it after that `initialize`.

/// The exit status of a terminal auth process that succeeded.
private let terminalAuthSuccessStatus: Int32 = 0

extension ConnectionModel {
    /// Runs a `terminal` auth method of the agent through a runner of the
    /// host.
    ///
    /// The call sends no ACP request. It gives the `args` of the method and
    /// its `env` to `runner`, which runs the agent program in an interactive
    /// terminal.
    ///
    /// - Exit status zero: ``authState`` becomes
    ///   ``AuthState/reconnectRequired(_:)``. The open connection is not
    ///   authenticated. The host must call
    ///   ``connect(over:logger:bufferLimits:client:)`` with a new transport
    ///   and then ``initialize(_:)``. When the answer of that `initialize`
    ///   still lists the method, ``authState`` becomes
    ///   ``AuthState/authenticated(_:)``. The host then retries the operation
    ///   that needed the login; the model does not retry it.
    /// - Another exit status, an end with no exit status, an error of the
    ///   runner, or a cancel of the calling task: ``authState`` becomes
    ///   ``AuthState/failed(_:)`` with the terminal login operation and the
    ///   terminal reason.
    ///
    /// When the last ``initialize(_:)`` did not send
    /// `capabilities.auth.terminal`, or the agent lists no `terminal` method
    /// with `methodId`, the call does not call `runner` and changes no state.
    ///
    /// - Parameters:
    ///   - methodId: The id of a `terminal` auth method that the agent lists.
    ///   - runner: The runner of the host that runs the agent program in an
    ///     interactive terminal.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` with
    ///   ``ConnectionModelError/terminalAuthOperation`` when the model must
    ///   not run the method,
    ///   ``ConnectionModelError/terminalAuthFailed(exitStatus:)`` when the
    ///   process did not exit with status zero, `CancellationError` when the
    ///   calling task was cancelled, or the error of the runner.
    public func loginWithTerminal(_ methodId: AuthMethodId, runner: any TerminalAuthRunner) async throws {
        let method = try runnableTerminalMethod(methodId)
        let exitStatus: Int32?
        do {
            try Task.checkCancellation()
            exitStatus = try await runner.runTerminalAuth(
                arguments: method.args ?? [],
                environment: method.environmentVariables
            )
            try Task.checkCancellation()
        } catch {
            recordTerminalLoginFailure(of: methodId, exitStatus: nil, message: String(describing: error))
            throw error
        }
        guard exitStatus == terminalAuthSuccessStatus else {
            recordTerminalLoginFailure(of: methodId, exitStatus: exitStatus, message: nil)
            throw ConnectionModelError.terminalAuthFailed(exitStatus: exitStatus)
        }
        pendingTerminalLogin = methodId
        authState = .reconnectRequired(methodId)
    }

    /// Gives the method of a successful terminal login when the agent still
    /// lists it as a `terminal` method, and forgets the login.
    ///
    /// ``initialize(_:)`` calls this after each answer, so a terminal login
    /// applies to one `initialize` only.
    ///
    /// - Returns: The id of the method, or `nil` when no terminal login
    ///   succeeded or the agent no longer lists the method.
    func takePendingTerminalLogin() -> AuthMethodId? {
        defer { pendingTerminalLogin = nil }
        guard let methodId = pendingTerminalLogin, listedTerminalMethod(methodId) != nil else {
            return nil
        }
        return methodId
    }

    /// Gives the `terminal` method that the model can run.
    ///
    /// - Parameter methodId: The id of the method.
    /// - Returns: The `terminal` method that the agent lists with `methodId`.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when the last
    ///   ``initialize(_:)`` did not send `capabilities.auth.terminal`, or the
    ///   agent lists no `terminal` method with `methodId`.
    private func runnableTerminalMethod(_ methodId: AuthMethodId) throws -> AuthMethodTerminal {
        guard hasAdvertisedTerminalAuth, let method = listedTerminalMethod(methodId) else {
            throw ConnectionModelError.unsupported(method: ConnectionModelError.terminalAuthOperation)
        }
        return method
    }

    /// Gives the `terminal` method that the agent lists with an id.
    ///
    /// - Parameter methodId: The id of the method.
    /// - Returns: The method, or `nil` when the agent lists no `terminal`
    ///   method with `methodId`.
    private func listedTerminalMethod(_ methodId: AuthMethodId) -> AuthMethodTerminal? {
        authMethods.lazy.compactMap(\.terminalMethod).first { $0.methodId == methodId }
    }

    /// Records a failed terminal login in ``authState``.
    ///
    /// - Parameters:
    ///   - methodId: The id of the `terminal` method.
    ///   - exitStatus: The exit status of the process, or `nil` when the
    ///     process gave none.
    ///   - message: A message about the failure, or `nil` when there is none.
    private func recordTerminalLoginFailure(of methodId: AuthMethodId, exitStatus: Int32?, message: String?) {
        authState = .failed(
            AuthFailure(
                operation: .terminalLogin(methodId),
                reason: .terminal(exitStatus: exitStatus, message: message)
            )
        )
    }
}

extension AuthMethod {
    /// The `terminal` method, or `nil` when this method is of another type.
    fileprivate var terminalMethod: AuthMethodTerminal? {
        guard case .terminal(let method) = self else { return nil }
        return method
    }
}

extension AuthMethodTerminal {
    /// The `env` of the method, keyed by name. ACP requires unique names;
    /// when a name comes again, the last value wins.
    fileprivate var environmentVariables: [String: String] {
        Dictionary((env ?? []).map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }
}
