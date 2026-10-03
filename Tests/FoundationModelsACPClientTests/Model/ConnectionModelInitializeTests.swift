import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the initialize and the auth part of `ConnectionModel`: the
// capability flags, `requireCapability(_:method:)`, the auth state, login and
// logout.
//
// `InMemoryTransport.pair()` gives the real ACP wire, with a
// `ScriptedStubAgent` on the agent end. The stub answers `initialize` with the
// capabilities and the auth methods of each test, and records each request
// that it gets, so a test can prove that a request did not go out.

/// A model that is connected over an in-memory pair to a scripted stub agent.
@MainActor
private struct ConnectedModel {
    /// The model under test.
    let model: ConnectionModel

    /// The agent-side connection. The test holds it so the agent end of the
    /// pair outlives the test body.
    let agentConnection: AgentSideConnection

    /// The stubs that the agent-side factory built. The factory runs one
    /// time, so the list holds one element.
    private let builtAgents: ThreadSafeBuffer<ScriptedStubAgent>

    /// The ACP method of each request that the agent got, in arrival order.
    var receivedMethods: [String] {
        (builtAgents.elements.last?.receivedMeta ?? []).map(\.method)
    }

    /// Connects a new model to a new stub agent.
    ///
    /// - Parameters:
    ///   - capabilities: The capabilities the agent answers `initialize`
    ///     with.
    ///   - authMethods: The auth methods the agent answers `initialize` with,
    ///     or `nil` to leave the member out.
    ///   - loginError: The error the agent refuses each login with, or `nil`
    ///     to accept each login.
    init(
        capabilities: AgentCapabilities = AgentCapabilities(),
        authMethods: [AuthMethod]? = nil,
        loginError: RequestError? = nil
    ) async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let builtAgents = ThreadSafeBuffer<ScriptedStubAgent>()
        self.builtAgents = builtAgents
        agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            let stub = ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: [],
                capabilities: capabilities,
                authMethods: authMethods,
                loginError: loginError
            )
            builtAgents.append(stub)
            return stub
        }
        model = ConnectionModel()
        _ = await model.connect(over: clientEnd)
    }

    /// Sends `initialize` through the model.
    ///
    /// - Returns: The answer of the agent.
    /// - Throws: Whatever the model threw.
    @discardableResult
    func initialize() async throws -> InitializeResponse {
        try await model.initialize(makeInitializeRequest())
    }
}

/// The fixtures of the initialize and auth tests.
private enum InitializeFixtures {
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

    /// A login with the agent auth method.
    static let login = LoginAuthRequest(methodId: agentMethodId)
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

        #expect(throws: ConnectionModelError.unsupported(method: ConnectionModel.WireMethod.logout)) {
            try model.requireCapability(false, method: ConnectionModel.WireMethod.logout)
        }
    }

    @Test func aPresentCapabilityThrowsNothing() throws {
        let model = ConnectionModel()

        try model.requireCapability(true, method: ConnectionModel.WireMethod.logout)
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
        #expect(connected.receivedMethods.contains(ConnectionModel.WireMethod.login))
    }

    @Test func aRefusedLoginFailsWithTheErrorOfTheAgent() async throws {
        let connected = await ConnectedModel(
            authMethods: [InitializeFixtures.agentMethod],
            loginError: InitializeFixtures.loginRefusal
        )
        try await connected.initialize()

        await #expect(throws: InitializeFixtures.loginRefusal) {
            try await connected.model.login(InitializeFixtures.login)
        }

        #expect(connected.model.authState == .failed(InitializeFixtures.loginRefusal))
    }

    @Test func aLogoutRequiresAuthAgain() async throws {
        let connected = await ConnectedModel(authMethods: [InitializeFixtures.agentMethod])
        try await connected.initialize()
        try await connected.model.login(InitializeFixtures.login)

        try await connected.model.logout(LogoutAuthRequest())

        #expect(connected.model.authState == .required([InitializeFixtures.agentMethod]))
        #expect(connected.receivedMethods.contains(ConnectionModel.WireMethod.logout))
    }

    @Test func aLogoutWithNoCapabilityThrowsUnsupportedAndSendsNothing() async throws {
        let connected = await ConnectedModel()
        try await connected.initialize()

        await #expect(throws: ConnectionModelError.unsupported(method: ConnectionModel.WireMethod.logout)) {
            try await connected.model.logout(LogoutAuthRequest())
        }
        // A second initialize makes a round trip after the refused logout, so
        // a logout that went out would be in the record before its answer.
        try await connected.initialize()

        #expect(connected.receivedMethods == [ClientRequestSpan.Method.initialize, ClientRequestSpan.Method.initialize])
        #expect(connected.model.authState == .notRequired)
    }
}
