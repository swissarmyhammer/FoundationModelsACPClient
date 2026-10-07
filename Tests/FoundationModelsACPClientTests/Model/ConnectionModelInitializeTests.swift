import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the initialize and the auth part of `ConnectionModel`: the
// capability flags, `requireCapability(_:method:)`, the auth state, login and
// logout.
//
// `ConnectedModel` gives the real ACP wire, with a `ScriptedStubAgent` on the
// agent end. The stub answers `initialize` with the capabilities and the auth
// methods of each test, and records each request that it gets, so a test can
// prove that a request did not go out.

/// The fixtures of the initialize and auth tests. The elicitation tests of
/// the connection model send the same login.
enum InitializeFixtures {
    /// The capabilities of an agent that advertises each optional session
    /// method.
    static let fullCapabilities = AgentCapabilities(
        session: SessionCapabilities(delete: SessionDeleteCapabilities())
    )

    /// The capabilities of an agent that advertises the session baseline and
    /// no `session/delete`.
    static let baselineCapabilities = AgentCapabilities(session: SessionCapabilities())

    /// The id of the auth method that the agent handles through `auth/login`.
    static let agentMethodId = AuthMethodId(rawValue: "api-key")

    /// An auth method that the agent handles through `auth/login`.
    static let agentMethod = AuthMethod.agent(AuthMethodAgent(methodId: agentMethodId, name: "API key"))

    /// An auth method that the client runs as a separate terminal process.
    static let terminalMethod = AuthMethod.terminal(
        AuthMethodTerminal(methodId: AuthMethodId(rawValue: "terminal-login"), name: "Terminal login")
    )

    /// The error that the agent refuses a login with.
    static let loginRefusal = RequestError.authenticationRequired

    /// The error that the agent refuses a logout with.
    static let logoutRefusal = RequestError.invalidParams

    /// A login with the agent auth method.
    static let login = LoginAuthRequest(methodId: agentMethodId)

    /// The failure that a login refused with ``loginRefusal`` records.
    static let loginRefusalFailure = AuthFailure(operation: .login(agentMethodId), reason: .request(loginRefusal))

    /// The failure that a logout refused with ``logoutRefusal`` records.
    static let logoutRefusalFailure = AuthFailure(operation: .logout, reason: .request(logoutRefusal))

    /// The failure that a request records when the connection closes before
    /// the agent answers it.
    ///
    /// - Parameter operation: The auth operation of the request.
    /// - Returns: The failure with the JSON-RPC form of
    ///   `ConnectionError.closed`.
    static func closedFailure(of operation: AuthFailure.Operation) -> AuthFailure {
        AuthFailure(operation: operation, reason: .request(RequestError(reporting: ConnectionError.closed)))
    }
}

/// The capability flags of a model, in one value, so a test compares them
/// all with one expectation.
private struct CapabilityFlags: Equatable {
    /// ``ConnectionModel/canListSessions``.
    let canListSessions: Bool

    /// ``ConnectionModel/canResumeSessions``.
    let canResumeSessions: Bool

    /// ``ConnectionModel/canCloseSessions``.
    let canCloseSessions: Bool

    /// ``ConnectionModel/canDeleteSessions``.
    let canDeleteSessions: Bool

    /// ``ConnectionModel/canLogout``.
    let canLogout: Bool

    /// The flags with each one false.
    static let none = CapabilityFlags(
        canListSessions: false,
        canResumeSessions: false,
        canCloseSessions: false,
        canDeleteSessions: false,
        canLogout: false
    )

    /// The flags with each one true.
    static let all = CapabilityFlags(
        canListSessions: true,
        canResumeSessions: true,
        canCloseSessions: true,
        canDeleteSessions: true,
        canLogout: true
    )
}

extension CapabilityFlags {
    /// Reads the flags of a model.
    ///
    /// The initializer stands in an extension, so the struct keeps its
    /// memberwise initializer.
    ///
    /// - Parameter model: The model to read.
    @MainActor
    init(of model: ConnectionModel) {
        self.init(
            canListSessions: model.canListSessions,
            canResumeSessions: model.canResumeSessions,
            canCloseSessions: model.canCloseSessions,
            canDeleteSessions: model.canDeleteSessions,
            canLogout: model.canLogout
        )
    }
}

/// The initialize and auth tests of the connection model, in one suite so
/// that `swift test --filter ConnectionModelInitializeTests` selects them.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionModelInitializeTests {
    // MARK: - Capability flags

    @Test func aNewModelHasNoCapabilityAndAnUnknownAuthState() {
        let model = ConnectionModel()

        #expect(CapabilityFlags(of: model) == .none)
        #expect(model.initializeResponse == nil)
        #expect(model.agentCapabilities == nil)
        #expect(model.authMethods.isEmpty)
        #expect(model.authState == .unknown)
    }

    @Test func aFullCapabilitySetSetsEachFlag() async throws {
        let connected = await ConnectedModel(
            capabilities: InitializeFixtures.fullCapabilities,
            authMethods: [InitializeFixtures.agentMethod]
        )

        let response = try await connected.initialize()

        #expect(CapabilityFlags(of: connected.model) == .all)
        #expect(connected.model.initializeResponse == response)
        #expect(connected.model.agentCapabilities == InitializeFixtures.fullCapabilities)
        #expect(connected.model.authMethods == [InitializeFixtures.agentMethod])
    }

    @Test func anEmptyCapabilitySetLeavesEachFlagFalse() async throws {
        let connected = await ConnectedModel()

        try await connected.initialize()

        #expect(CapabilityFlags(of: connected.model) == .none)
        #expect(connected.model.agentCapabilities == AgentCapabilities())
    }

    @Test func theSessionBaselineWithoutDeleteCannotDelete() async throws {
        let connected = await ConnectedModel(capabilities: InitializeFixtures.baselineCapabilities)

        try await connected.initialize()

        let expected = CapabilityFlags(
            canListSessions: true,
            canResumeSessions: true,
            canCloseSessions: true,
            canDeleteSessions: false,
            canLogout: false
        )
        #expect(CapabilityFlags(of: connected.model) == expected)
    }

    @Test func terminalAuthMethodsAloneCannotLogout() async throws {
        let connected = await ConnectedModel(authMethods: [InitializeFixtures.terminalMethod])

        try await connected.initialize()

        #expect(!connected.model.canLogout)
        #expect(connected.model.authState == .required([InitializeFixtures.terminalMethod]))
    }

    @Test func aNewConnectionForgetsTheInitializeOfTheLastOne() async throws {
        let connected = await ConnectedModel(
            capabilities: InitializeFixtures.fullCapabilities,
            authMethods: [InitializeFixtures.agentMethod]
        )
        try await connected.initialize()
        let (clientEnd, _) = InMemoryTransport.pair()

        _ = await connected.model.connect(over: clientEnd)

        #expect(CapabilityFlags(of: connected.model) == .none)
        #expect(connected.model.initializeResponse == nil)
        #expect(connected.model.authState == .unknown)
    }

    @Test func initializeWithNoConnectionThrowsClosed() async {
        let model = ConnectionModel()

        await #expect(throws: ConnectionError.closed) {
            try await model.initialize(makeInitializeRequest())
        }
    }

    // MARK: - requireCapability

    @Test func aMissingCapabilityThrowsUnsupported() {
        let model = ConnectionModel()

        #expect(throws: ConnectionModelError.unsupported(method: ClientRequestSpan.Method.logout)) {
            try model.requireCapability(false, method: ClientRequestSpan.Method.logout)
        }
    }

    @Test func aPresentCapabilityThrowsNothing() throws {
        let model = ConnectionModel()

        try model.requireCapability(true, method: ClientRequestSpan.Method.logout)
    }

    // MARK: - Auth state

    @Test func noAuthMethodMeansNoAuthIsRequired() async throws {
        let connected = await ConnectedModel()

        try await connected.initialize()

        #expect(connected.model.authState == .notRequired)
    }

    @Test func listedAuthMethodsRequireAuth() async throws {
        let connected = await ConnectedModel(authMethods: [InitializeFixtures.agentMethod])

        try await connected.initialize()

        #expect(connected.model.authState == .required([InitializeFixtures.agentMethod]))
    }

    @Test func aSuccessfulLoginAuthenticatesWithItsMethod() async throws {
        let connected = await ConnectedModel(authMethods: [InitializeFixtures.agentMethod])
        try await connected.initialize()

        try await connected.model.login(InitializeFixtures.login)

        #expect(connected.model.authState == .authenticated(InitializeFixtures.agentMethodId))
        #expect(connected.receivedMethods.contains(ClientRequestSpan.Method.login))
    }

    @Test func aRefusedLoginRecordsTheLoginOperationAndTheAgentError() async throws {
        let connected = await ConnectedModel(
            authMethods: [InitializeFixtures.agentMethod],
            loginError: InitializeFixtures.loginRefusal
        )
        try await connected.initialize()

        await #expect(throws: InitializeFixtures.loginRefusal) {
            try await connected.model.login(InitializeFixtures.login)
        }

        #expect(connected.model.authState == .failed(InitializeFixtures.loginRefusalFailure))
    }

    @Test func aLoginThatTheConnectionCloseEndsRecordsAFailure() async throws {
        let loginGate = UpdateGate()
        let connected = await ConnectedModel(authMethods: [InitializeFixtures.agentMethod], loginGate: loginGate)
        try await connected.initialize()

        try await closeTheConnection(of: connected, during: ClientRequestSpan.Method.login) { model in
            try await model.login(InitializeFixtures.login)
        }

        let expected = InitializeFixtures.closedFailure(of: .login(InitializeFixtures.agentMethodId))
        #expect(connected.model.authState == .failed(expected))
        loginGate.open()
    }

    @Test func aRefusedLogoutRecordsTheLogoutOperation() async throws {
        let connected = await ConnectedModel(
            authMethods: [InitializeFixtures.agentMethod],
            logoutError: InitializeFixtures.logoutRefusal
        )
        try await connected.initialize()

        await #expect(throws: InitializeFixtures.logoutRefusal) {
            try await connected.model.logout(LogoutAuthRequest())
        }

        #expect(connected.model.authState == .failed(InitializeFixtures.logoutRefusalFailure))
    }

    @Test func aLogoutThatTheConnectionCloseEndsRecordsAFailure() async throws {
        let logoutGate = UpdateGate()
        let connected = await ConnectedModel(authMethods: [InitializeFixtures.agentMethod], logoutGate: logoutGate)
        try await connected.initialize()

        try await closeTheConnection(of: connected, during: ClientRequestSpan.Method.logout) { model in
            try await model.logout(LogoutAuthRequest())
        }

        #expect(connected.model.authState == .failed(InitializeFixtures.closedFailure(of: .logout)))
        logoutGate.open()
    }

    @Test func aSuccessfulLoginAfterARefusedLogoutAuthenticates() async throws {
        let connected = await ConnectedModel(
            authMethods: [InitializeFixtures.agentMethod],
            logoutError: InitializeFixtures.logoutRefusal
        )
        try await connected.initialize()
        await #expect(throws: InitializeFixtures.logoutRefusal) {
            try await connected.model.logout(LogoutAuthRequest())
        }
        try #require(connected.model.authState == .failed(InitializeFixtures.logoutRefusalFailure))

        try await connected.model.login(InitializeFixtures.login)

        #expect(connected.model.authState == .authenticated(InitializeFixtures.agentMethodId))
    }

    @Test func aSuccessfulLogoutAfterARefusedLoginRequiresAuth() async throws {
        let connected = await ConnectedModel(
            authMethods: [InitializeFixtures.agentMethod],
            loginError: InitializeFixtures.loginRefusal
        )
        try await connected.initialize()
        await #expect(throws: InitializeFixtures.loginRefusal) {
            try await connected.model.login(InitializeFixtures.login)
        }
        try #require(connected.model.authState == .failed(InitializeFixtures.loginRefusalFailure))

        try await connected.model.logout(LogoutAuthRequest())

        #expect(connected.model.authState == .required([InitializeFixtures.agentMethod]))
    }

    @Test func aLoginWithNoOpenConnectionKeepsTheAuthState() async throws {
        let connected = await ConnectedModel(authMethods: [InitializeFixtures.agentMethod])
        try await connected.initialize()
        connected.agentEnd.close()
        try await waitUntil { connected.model.state == .disconnected }

        await #expect(throws: ConnectionError.closed) {
            try await connected.model.login(InitializeFixtures.login)
        }

        #expect(connected.model.authState == .required([InitializeFixtures.agentMethod]))
    }

    @Test func aLogoutWithNoCapabilityKeepsTheAuthState() async throws {
        let connected = await ConnectedModel(authMethods: [InitializeFixtures.terminalMethod])
        try await connected.initialize()

        await #expect(throws: ConnectionModelError.unsupported(method: ClientRequestSpan.Method.logout)) {
            try await connected.model.logout(LogoutAuthRequest())
        }

        #expect(connected.model.authState == .required([InitializeFixtures.terminalMethod]))
    }

    @Test func aLogoutRequiresAuthAgain() async throws {
        let connected = await ConnectedModel(authMethods: [InitializeFixtures.agentMethod])
        try await connected.initialize()
        try await connected.model.login(InitializeFixtures.login)

        try await connected.model.logout(LogoutAuthRequest())

        #expect(connected.model.authState == .required([InitializeFixtures.agentMethod]))
        #expect(connected.receivedMethods.contains(ClientRequestSpan.Method.logout))
    }

    @Test func aLogoutWithNoCapabilityThrowsUnsupportedAndSendsNothing() async throws {
        let connected = await ConnectedModel()
        try await connected.initialize()

        await #expect(throws: ConnectionModelError.unsupported(method: ClientRequestSpan.Method.logout)) {
            try await connected.model.logout(LogoutAuthRequest())
        }
        // A second initialize makes a round trip after the refused logout, so
        // a logout that went out would be in the record before its answer.
        try await connected.initialize()

        #expect(connected.receivedMethods == [ClientRequestSpan.Method.initialize, ClientRequestSpan.Method.initialize])
        #expect(connected.model.authState == .notRequired)
    }

    // MARK: - Helpers

    /// Sends a request through the model, closes the agent end of the pair
    /// while the agent holds that request at its gate, and expects that the
    /// request throws `ConnectionError.closed`.
    ///
    /// The agent records the method of the request before it waits at the
    /// gate, so the record tells that the request is in flight. No sleep is
    /// necessary.
    ///
    /// - Parameters:
    ///   - connected: The connected model.
    ///   - method: The ACP method of the request.
    ///   - send: Sends the request through the model.
    /// - Throws: `CancellationError` when the test time limit cancels the wait.
    private func closeTheConnection(
        of connected: ConnectedModel,
        during method: String,
        _ send: @escaping @Sendable @MainActor (ConnectionModel) async throws -> Void
    ) async throws {
        let model = connected.model
        let request = Task { try await send(model) }
        try await waitUntil { connected.receivedMethods.contains(method) }

        connected.agentEnd.close()

        await #expect(throws: ConnectionError.closed) {
            try await request.value
        }
    }
}
