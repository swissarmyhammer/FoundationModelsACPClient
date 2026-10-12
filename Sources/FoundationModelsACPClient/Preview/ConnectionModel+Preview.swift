import FoundationModelsACP

// The preview factory of `ConnectionModel`: a model with a state, a session
// list and open sessions, but with no agent and no connection, for a SwiftUI
// `#Preview` or a test of a host app.

extension ConnectionModel {
    /// Makes a model with the given state and no connection.
    ///
    /// The model holds each open session through the same registration that
    /// a live `session/new` or `session/resume` uses, so ``openSessions`` and
    /// ``session(for:)`` work as they do on a live model. The model never
    /// opens a process or a socket. Each request that needs the connection,
    /// for example ``newSession(_:)``, throws `ConnectionError.closed`.
    ///
    /// ```swift
    /// #Preview {
    ///     SessionsView(connection: .preview(openSessions: [.previewSample]))
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - state: The state of the connection.
    ///   - sessions: The sessions of the session list, in order.
    ///   - openSessions: The models of the open sessions, in order. A model
    ///     with the session id of an earlier model replaces that model in its
    ///     position.
    ///   - authState: The auth state of the connection.
    ///   - initializeResponse: The `initialize` answer of the agent, or `nil`
    ///     when the connection did not initialize.
    /// - Returns: The model.
    public static func preview(
        state: ConnectionState = .connected,
        sessions: [SessionInfo] = [],
        openSessions: [SessionModel] = [],
        authState: AuthState = .unknown,
        initializeResponse: InitializeResponse? = nil
    ) -> ConnectionModel {
        let model = ConnectionModel(
            coalescingCadence: .zero,
            clock: PreviewClock(),
            now: { SessionModel.previewDate }
        )
        model.state = state
        model.sessions = sessions
        model.authState = authState
        model.initializeResponse = initializeResponse
        for session in openSessions {
            model.register(session)
        }
        return model
    }

    /// A new preview model of an initialized connection that needs no login,
    /// with two open sessions that its session list also lists. The first
    /// session is ``SessionModel/previewSample``.
    public static var previewSample: ConnectionModel {
        let first = SessionModel.previewSample
        let second = SessionModel.preview(
            sessionId: SessionId(rawValue: "preview-session-tests"),
            cwd: SessionModel.previewSampleCwd,
            transcript: [
                .user("Add a test for the parser."),
                .agent("I added ParserTests.swift, and the tests pass."),
                .terminal(command: "swift test", output: "All tests passed.", exitCode: 0),
            ]
        )
        return preview(
            sessions: [
                SessionInfo(cwd: SessionModel.previewSampleCwd, sessionId: first.sessionId, title: "Fix the build"),
                SessionInfo(cwd: SessionModel.previewSampleCwd, sessionId: second.sessionId, title: "Parser tests"),
            ],
            openSessions: [first, second],
            authState: .notRequired,
            initializeResponse: InitializeResponse(
                info: Implementation(name: "preview-agent", version: "1.0.0"),
                protocolVersion: ACPClient.supportedProtocolVersion
            )
        )
    }
}
