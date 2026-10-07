import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the `-32000` answer to a request of `ConnectionModel`, and to
// the prompt and the config change of a session model that it made: the
// answer sets `authState` to `.required` with the auth methods of the agent,
// and the call still throws the error. A session of an earlier connection
// does not change the state of the open connection.
//
// `ConnectedModel` gives the real ACP wire, with a `ScriptedStubAgent` on the
// agent end. The stub refuses the request of each test with the error that
// the test chose.
//
// After `initialize`, `authState` is already `.required`. Thus each test
// first moves the state to another value, with a refused login or with a
// login, so that only the `-32000` answer can make it `.required` again.

/// The fixtures of the auth-required tests.
private enum AuthRequiredFixtures {
    /// The working directory of each session request that the tests send.
    static let workingDirectory = AbsolutePath(rawValue: "/")

    /// The new-session request that each test sends.
    static let newSessionRequest = NewSessionRequest(cwd: workingDirectory)

    /// The resume request of the test session.
    static let resumeRequest = ResumeSessionRequest(
        cwd: workingDirectory,
        sessionId: testSession,
        replayFrom: .start(ReplayFromStart())
    )

    /// The content of each prompt that the tests send.
    static let promptContent: [ContentBlock] = [.text(TextContent(text: "Auth required prompt"))]

    /// The request that changes the mode of the test session.
    static let setModeRequest = SetSessionConfigOptionRequest(
        configId: SessionConfigId(rawValue: "mode"),
        sessionId: testSession,
        value: .id(SessionConfigValueId(rawValue: "fast"))
    )

    /// The answer of an agent that needs a login before the request.
    static let authRequired = RequestError.authenticationRequired

    /// An error that is not the `-32000` answer.
    static let otherError = RequestError.invalidParams

    /// The state after a successful login with the agent auth method.
    static let authenticated = AuthState.authenticated(InitializeFixtures.agentMethodId)

    /// The state that a `-32000` answer gives.
    static let required = AuthState.required([InitializeFixtures.agentMethod])

    /// The state after a login that the agent refused with ``otherError``.
    static let failedLogin = AuthState.failed(
        AuthFailure(operation: .login(InitializeFixtures.agentMethodId), reason: .request(otherError))
    )

    /// Connects a model to a stub agent that lists the agent auth method,
    /// advertises each optional session method, and refuses the requests
    /// that the test chose.
    ///
    /// - Parameters:
    ///   - model: The model to connect. A test that connects one model two
    ///     times gives the model of the first connection.
    ///   - loginError: The error the agent refuses each login with, or `nil`
    ///     to accept each login.
    ///   - newSessionError: The error the agent refuses each `session/new`
    ///     with, or `nil` to answer each new session.
    ///   - resumeSessionError: The error the agent refuses each
    ///     `session/resume` with, or `nil` to accept each resume.
    ///   - listSessionsError: The error the agent refuses each
    ///     `session/list` with, or `nil` to answer each list.
    ///   - closeSessionError: The error the agent refuses each
    ///     `session/close` with, or `nil` to accept each close.
    ///   - deleteSessionError: The error the agent refuses each
    ///     `session/delete` with, or `nil` to accept each delete.
    ///   - promptError: The error the agent refuses each `session/prompt`
    ///     with, or `nil` to answer each prompt.
    ///   - setConfigOptionError: The error the agent refuses each
    ///     `session/set_config_option` with, or `nil` to accept each request.
    /// - Returns: The connected model, after `initialize`.
    /// - Throws: Whatever `initialize` threw.
    @MainActor
    static func connect(
        model: ConnectionModel = ConnectionModel(coalescingCadence: .zero),
        loginError: RequestError? = nil,
        newSessionError: RequestError? = nil,
        resumeSessionError: RequestError? = nil,
        listSessionsError: RequestError? = nil,
        closeSessionError: RequestError? = nil,
        deleteSessionError: RequestError? = nil,
        promptError: RequestError? = nil,
        setConfigOptionError: RequestError? = nil
    ) async throws -> ConnectedModel {
        let connected = await ConnectedModel(model: model) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: [],
                promptError: promptError,
                closeSessionError: closeSessionError,
                newSessionError: newSessionError,
                listSessionsError: listSessionsError,
                deleteSessionError: deleteSessionError,
                setConfigOptionError: setConfigOptionError,
                resumeSessionError: resumeSessionError,
                capabilities: InitializeFixtures.fullCapabilities,
                authMethods: [InitializeFixtures.agentMethod],
                loginError: loginError
            )
        }
        try await connected.initialize()
        return connected
    }

    /// Connects a model whose login the agent refuses, so that ``failedLogin``
    /// is the auth state before the request of the test.
    ///
    /// - Parameters:
    ///   - newSessionError: The error the agent refuses each `session/new`
    ///     with, or `nil` to answer each new session.
    ///   - resumeSessionError: The error the agent refuses each
    ///     `session/resume` with, or `nil` to accept each resume.
    ///   - listSessionsError: The error the agent refuses each
    ///     `session/list` with, or `nil` to answer each list.
    ///   - closeSessionError: The error the agent refuses each
    ///     `session/close` with, or `nil` to accept each close.
    ///   - deleteSessionError: The error the agent refuses each
    ///     `session/delete` with, or `nil` to accept each delete.
    ///   - promptError: The error the agent refuses each `session/prompt`
    ///     with, or `nil` to answer each prompt.
    ///   - setConfigOptionError: The error the agent refuses each
    ///     `session/set_config_option` with, or `nil` to accept each request.
    /// - Returns: The connected model, with ``failedLogin`` as its auth state.
    /// - Throws: Whatever `initialize` threw, or a failed requirement when
    ///   the login does not give ``failedLogin``.
    @MainActor
    static func connectAfterARefusedLogin(
        newSessionError: RequestError? = nil,
        resumeSessionError: RequestError? = nil,
        listSessionsError: RequestError? = nil,
        closeSessionError: RequestError? = nil,
        deleteSessionError: RequestError? = nil,
        promptError: RequestError? = nil,
        setConfigOptionError: RequestError? = nil
    ) async throws -> ConnectedModel {
        let connected = try await connect(
            loginError: otherError,
            newSessionError: newSessionError,
            resumeSessionError: resumeSessionError,
            listSessionsError: listSessionsError,
            closeSessionError: closeSessionError,
            deleteSessionError: deleteSessionError,
            promptError: promptError,
            setConfigOptionError: setConfigOptionError
        )
        await #expect(throws: otherError) {
            try await connected.model.login(InitializeFixtures.login)
        }
        try #require(connected.model.authState == failedLogin)
        return connected
    }
}

/// The auth-required tests of the connection model, in one suite so that
/// `swift test --filter ConnectionModelAuthRequiredTests` selects them.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionModelAuthRequiredTests {
    // MARK: - Each request

    @Test func aNewSessionThatNeedsAuthSetsRequired() async throws {
        let connected = try await AuthRequiredFixtures.connectAfterARefusedLogin(
            newSessionError: AuthRequiredFixtures.authRequired
        )

        await #expect(throws: AuthRequiredFixtures.authRequired) {
            try await connected.model.newSession(AuthRequiredFixtures.newSessionRequest)
        }

        #expect(connected.model.authState == AuthRequiredFixtures.required)
    }

    @Test func aResumeThatNeedsAuthSetsRequired() async throws {
        let connected = try await AuthRequiredFixtures.connectAfterARefusedLogin(
            resumeSessionError: AuthRequiredFixtures.authRequired
        )

        await #expect(throws: AuthRequiredFixtures.authRequired) {
            try await connected.model.resumeSession(AuthRequiredFixtures.resumeRequest)
        }

        #expect(connected.model.authState == AuthRequiredFixtures.required)
    }

    @Test func aListThatNeedsAuthSetsRequired() async throws {
        let connected = try await AuthRequiredFixtures.connectAfterARefusedLogin(
            listSessionsError: AuthRequiredFixtures.authRequired
        )

        await #expect(throws: AuthRequiredFixtures.authRequired) {
            try await connected.model.refreshSessions()
        }

        #expect(connected.model.authState == AuthRequiredFixtures.required)
    }

    @Test func aCloseThatNeedsAuthSetsRequired() async throws {
        let connected = try await AuthRequiredFixtures.connectAfterARefusedLogin(
            closeSessionError: AuthRequiredFixtures.authRequired
        )
        let session = try await connected.model.newSession(AuthRequiredFixtures.newSessionRequest)

        await #expect(throws: AuthRequiredFixtures.authRequired) {
            try await connected.model.close(session)
        }

        #expect(connected.model.authState == AuthRequiredFixtures.required)
    }

    @Test func aDeleteThatNeedsAuthSetsRequired() async throws {
        let connected = try await AuthRequiredFixtures.connectAfterARefusedLogin(
            deleteSessionError: AuthRequiredFixtures.authRequired
        )

        await #expect(throws: AuthRequiredFixtures.authRequired) {
            try await connected.model.deleteSession(testSession)
        }

        #expect(connected.model.authState == AuthRequiredFixtures.required)
    }

    // MARK: - Each request of a session

    @Test func aPromptThatNeedsAuthSetsRequired() async throws {
        let connected = try await AuthRequiredFixtures.connectAfterARefusedLogin(
            promptError: AuthRequiredFixtures.authRequired
        )
        let session = try await connected.model.newSession(AuthRequiredFixtures.newSessionRequest)

        await #expect(throws: AuthRequiredFixtures.authRequired) {
            try await session.prompt(AuthRequiredFixtures.promptContent)
        }

        #expect(connected.model.authState == AuthRequiredFixtures.required)
        let prompt = try #require(session.transcript.first?.userMessage)
        #expect(prompt.sendState == .failed)
        let error = try #require(session.transcript.last?.error)
        #expect(error.code == .authenticationRequired)
    }

    @Test func aConfigChangeThatNeedsAuthSetsRequired() async throws {
        let connected = try await AuthRequiredFixtures.connectAfterARefusedLogin(
            setConfigOptionError: AuthRequiredFixtures.authRequired
        )
        let session = try await connected.model.newSession(AuthRequiredFixtures.newSessionRequest)

        await #expect(throws: AuthRequiredFixtures.authRequired) {
            try await session.setConfigOption(AuthRequiredFixtures.setModeRequest)
        }

        #expect(connected.model.authState == AuthRequiredFixtures.required)
    }

    @Test func aPromptWithAnotherErrorKeepsTheAuthState() async throws {
        let connected = try await AuthRequiredFixtures.connectAfterARefusedLogin(
            promptError: AuthRequiredFixtures.otherError
        )
        let session = try await connected.model.newSession(AuthRequiredFixtures.newSessionRequest)

        await #expect(throws: AuthRequiredFixtures.otherError) {
            try await session.prompt(AuthRequiredFixtures.promptContent)
        }

        #expect(connected.model.authState == AuthRequiredFixtures.failedLogin)
    }

    @Test func aSessionOfAnEarlierConnectionDoesNotChangeTheAuthState() async throws {
        let earlier = try await AuthRequiredFixtures.connect(promptError: AuthRequiredFixtures.authRequired)
        let session = try await earlier.model.newSession(AuthRequiredFixtures.newSessionRequest)
        let current = try await AuthRequiredFixtures.connect(model: earlier.model)
        try await current.model.login(InitializeFixtures.login)
        try #require(current.model.authState == AuthRequiredFixtures.authenticated)

        await #expect(throws: AuthRequiredFixtures.authRequired) {
            try await session.prompt(AuthRequiredFixtures.promptContent)
        }

        #expect(earlier.receivedMethods.last == ClientRequestSpan.Method.prompt)
        #expect(current.model.authState == AuthRequiredFixtures.authenticated)
    }

    // MARK: - The state before the answer

    @Test func anAuthenticatedConnectionGoesBackToRequired() async throws {
        let connected = try await AuthRequiredFixtures.connect(newSessionError: AuthRequiredFixtures.authRequired)
        try await connected.model.login(InitializeFixtures.login)
        try #require(connected.model.authState == AuthRequiredFixtures.authenticated)

        await #expect(throws: AuthRequiredFixtures.authRequired) {
            try await connected.model.newSession(AuthRequiredFixtures.newSessionRequest)
        }

        #expect(connected.model.authState == AuthRequiredFixtures.required)
    }

    @Test func anotherErrorKeepsTheAuthState() async throws {
        let connected = try await AuthRequiredFixtures.connect(newSessionError: AuthRequiredFixtures.otherError)
        try await connected.model.login(InitializeFixtures.login)
        try #require(connected.model.authState == AuthRequiredFixtures.authenticated)

        await #expect(throws: AuthRequiredFixtures.otherError) {
            try await connected.model.newSession(AuthRequiredFixtures.newSessionRequest)
        }

        #expect(connected.model.authState == AuthRequiredFixtures.authenticated)
    }

    // MARK: - The clear

    @Test func aLoginAfterRequiredGivesAuthenticated() async throws {
        let connected = try await AuthRequiredFixtures.connect(newSessionError: AuthRequiredFixtures.authRequired)
        try await connected.model.login(InitializeFixtures.login)
        await #expect(throws: AuthRequiredFixtures.authRequired) {
            try await connected.model.newSession(AuthRequiredFixtures.newSessionRequest)
        }
        try #require(connected.model.authState == AuthRequiredFixtures.required)

        try await connected.model.login(InitializeFixtures.login)

        #expect(connected.model.authState == AuthRequiredFixtures.authenticated)
    }
}
