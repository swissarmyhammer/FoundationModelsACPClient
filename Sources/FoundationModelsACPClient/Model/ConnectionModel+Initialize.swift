import FoundationModelsACP

// The initialize and the auth part of `ConnectionModel`: the `initialize`
// answer, the capability flags that it gives, the auth state, login, and
// logout.
//
// The capability flags follow the advertisement rules of the ACP schema of
// alpha.7. The schema has no flag of its own for `session/list`,
// `session/resume`, `session/close`, or `auth/logout`:
//
// - A `capabilities.session` object advertises the session baseline, which
//   holds `session/list`, `session/resume`, and `session/close`.
// - `capabilities.session.delete` advertises `session/delete`.
// - An `authMethods` entry that is not a `terminal` method advertises
//   `auth/login` and `auth/logout`. The client runs a `terminal` method as a
//   separate process and never sends it to `auth/login`.
//
// Each request goes out in a client request span, through
// `ClientRequestSpan.send(_:parent:through:)`: the span, the request metrics,
// and the W3C trace context in the `_meta` of the request.

extension ConnectionModel {
    // MARK: - Capabilities

    /// The capabilities of the agent, or `nil` before ``initialize(_:)``
    /// succeeds.
    public var agentCapabilities: AgentCapabilities? {
        initializeResponse?.capabilities
    }

    /// The auth methods of the agent. The list is empty before
    /// ``initialize(_:)`` succeeds, and when the agent lists none.
    public var authMethods: [AuthMethod] {
        initializeResponse?.authMethods ?? []
    }

    /// Tells whether the agent serves `session/list`. It is `false` before
    /// ``initialize(_:)`` succeeds.
    public var canListSessions: Bool {
        advertisesSessionBaseline
    }

    /// Tells whether the agent serves `session/resume`. It is `false` before
    /// ``initialize(_:)`` succeeds.
    public var canResumeSessions: Bool {
        advertisesSessionBaseline
    }

    /// Tells whether the agent serves `session/close`. It is `false` before
    /// ``initialize(_:)`` succeeds.
    public var canCloseSessions: Bool {
        advertisesSessionBaseline
    }

    /// Tells whether the agent serves `session/delete`. It is `false` before
    /// ``initialize(_:)`` succeeds.
    public var canDeleteSessions: Bool {
        agentCapabilities?.session?.delete != nil
    }

    /// Tells whether the agent serves `auth/logout`. It is `false` before
    /// ``initialize(_:)`` succeeds.
    public var canLogout: Bool {
        authMethods.contains(where: \.isSentToLogin)
    }

    /// Tells whether the agent advertises the session baseline.
    private var advertisesSessionBaseline: Bool {
        agentCapabilities?.session != nil
    }

    /// Throws when the agent does not advertise the capability of a method.
    ///
    /// A method of the model calls this before it sends its request, so a
    /// method that the agent does not serve sends nothing.
    ///
    /// - Parameters:
    ///   - isSupported: The capability flag of the method.
    ///   - method: The ACP wire method, for the error.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when
    ///   `isSupported` is `false`.
    func requireCapability(_ isSupported: Bool, method: String) throws {
        guard isSupported else {
            throw ConnectionModelError.unsupported(method: method)
        }
    }

    // MARK: - Initialize

    /// Sends `initialize` and keeps the answer.
    ///
    /// The answer sets ``initializeResponse``, each capability flag, and
    /// ``authState``: ``AuthState/notRequired`` when the agent lists no auth
    /// method, and ``AuthState/required(_:)`` with the methods otherwise.
    ///
    /// - Parameter request: The initialize request.
    /// - Returns: The answer of the agent.
    /// - Throws: `ConnectionError.closed` when no connection is open, or the
    ///   error of the connection.
    public func initialize(_ request: InitializeRequest) async throws -> InitializeResponse {
        let connection = try openConnection()
        let response = try await ClientRequestSpan.send(request) { try await connection.initialize($0) }
        initializeResponse = response
        authState = AuthState(advertising: authMethods)
        return response
    }

    // MARK: - Auth

    /// Sends `auth/login`.
    ///
    /// When the agent accepts the login, ``authState`` becomes
    /// ``AuthState/authenticated(_:)`` with the method of the request. When
    /// the request fails, ``authState`` becomes ``AuthState/failed(_:)`` with
    /// the login operation and the JSON-RPC form of the error: the refusal of
    /// the agent, a closed connection, a time-out, or a cancel. When no
    /// connection is open, the call sends nothing and changes no state.
    ///
    /// - Parameter request: The login request.
    /// - Throws: `ConnectionError.closed` when no connection is open, the
    ///   `RequestError` of the agent, or the error of the connection.
    public func login(_ request: LoginAuthRequest) async throws {
        let connection = try openConnection()
        try await recordingFailure(of: .login(request.methodId)) {
            _ = try await ClientRequestSpan.send(request) { try await connection.loginAuth($0) }
        }
        authState = .authenticated(request.methodId)
    }

    /// Sends `auth/logout`.
    ///
    /// When the agent accepts the logout, ``authState`` becomes
    /// ``AuthState/required(_:)`` with the auth methods of the agent. When
    /// the request fails, ``authState`` becomes ``AuthState/failed(_:)`` with
    /// the logout operation and the JSON-RPC form of the error, and no other
    /// state changes. When ``canLogout`` is `false`, or when no connection is
    /// open, the call sends nothing and changes no state.
    ///
    /// - Parameter request: The logout request.
    /// - Throws: ``ConnectionModelError/unsupported(method:)`` when
    ///   ``canLogout`` is `false`, `ConnectionError.closed` when no connection
    ///   is open, or the error of the agent or of the connection.
    public func logout(_ request: LogoutAuthRequest) async throws {
        try requireCapability(canLogout, method: ClientRequestSpan.Method.logout)
        let connection = try openConnection()
        try await recordingFailure(of: .logout) {
            _ = try await ClientRequestSpan.send(request) { try await connection.logoutAuth($0) }
        }
        authState = .required(authMethods)
    }

    /// Runs one auth request, and records each error that it throws in
    /// ``authState``.
    ///
    /// ``RequestError/init(reporting:)`` gives the reason, so each error has
    /// one JSON-RPC form.
    ///
    /// - Parameters:
    ///   - operation: The auth operation of the request.
    ///   - send: Sends the request.
    /// - Throws: The error that `send` threw, after the record.
    private func recordingFailure(
        of operation: AuthFailure.Operation,
        _ send: () async throws -> Void
    ) async throws {
        do {
            try await send()
        } catch {
            authState = .failed(AuthFailure(operation: operation, reason: .request(RequestError(reporting: error))))
            throw error
        }
    }

    // MARK: - Connection

    /// Gives the open connection.
    ///
    /// The session part of the model sends its requests over this connection
    /// too.
    ///
    /// - Returns: The open connection.
    /// - Throws: `ConnectionError.closed` when no connection is open.
    func openConnection() throws -> ClientSideConnection {
        guard let connection else {
            throw ConnectionError.closed
        }
        return connection
    }
}

extension AuthMethod {
    /// Tells whether the client sends this method to `auth/login`. The client
    /// runs a `terminal` method as a separate process, and sends each other
    /// method, an unknown one too, to `auth/login`.
    fileprivate var isSentToLogin: Bool {
        switch self {
        case .terminal:
            false
        case .agent, .unknown:
            true
        }
    }
}
