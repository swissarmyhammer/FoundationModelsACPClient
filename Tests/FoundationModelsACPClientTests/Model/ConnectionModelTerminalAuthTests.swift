import FoundationModelsACP
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// The tests of the terminal auth part of `ConnectionModel`: the run of a
// `terminal` auth method through a runner of the host, the reconnect that a
// successful run requires, and the `initialize` that then gives
// `authenticated`.
//
// `ConnectedModel` gives the real ACP wire, with a `ScriptedStubAgent` on the
// agent end. The stub lists one `terminal` method and one `agent` method, and
// records each request that it gets, so a test can prove that no request
// went out. `FakeTerminalAuthRunner` stands in for the interactive terminal of
// the host. No test sleeps.

/// The fixtures of the terminal auth tests.
private enum TerminalAuthFixtures {
    /// The arguments that the terminal method appends to the agent command.
    static let arguments = ["--login"]

    /// The name of the environment variable that the terminal method sets.
    static let environmentName = "LOGIN_MODE"

    /// The value of the environment variable that the terminal method sets.
    static let environmentValue = "interactive"

    /// The terminal auth method, with its arguments and its environment.
    static let terminalMethod = AuthMethod.terminal(
        AuthMethodTerminal(
            methodId: InitializeFixtures.terminalMethodId,
            name: "Terminal login",
            args: arguments,
            env: [EnvVariable(name: environmentName, value: environmentValue)]
        )
    )

    /// The auth methods that the agent lists: one `terminal` method and one
    /// `agent` method.
    static let authMethods = [terminalMethod, InitializeFixtures.agentMethod]

    /// The exit status of a terminal auth process that failed.
    static let failureExitStatus: Int32 = 1

    /// Makes an initialize request that advertises `auth.terminal`.
    ///
    /// - Returns: The request of the tests, with the terminal auth
    ///   capability.
    static func terminalInitializeRequest() -> InitializeRequest {
        var request = makeInitializeRequest()
        request.capabilities.auth = AuthCapabilities(terminal: TerminalAuthCapabilities())
        return request
    }

    /// The failure that a failed terminal login records.
    ///
    /// - Parameters:
    ///   - exitStatus: The exit status of the process, or `nil`.
    ///   - message: The message about the failure, or `nil`.
    /// - Returns: The failure of the terminal login of the terminal method.
    static func failure(exitStatus: Int32?, message: String?) -> AuthFailure {
        AuthFailure(
            operation: .terminalLogin(InitializeFixtures.terminalMethodId),
            reason: .terminal(exitStatus: exitStatus, message: message)
        )
    }

    /// The failure that a terminal login records when the model must not run
    /// the method.
    ///
    /// - Parameter methodId: The method id of the terminal login.
    /// - Returns: The failure of the terminal login, with the unsupported
    ///   reason of ``ConnectionModelError/terminalAuthOperation``.
    static func unsupportedFailure(of methodId: AuthMethodId) -> AuthFailure {
        AuthFailureFixtures.unsupportedFailure(
            of: .terminalLogin(methodId),
            method: ConnectionModelError.terminalAuthOperation
        )
    }
}

/// The error of a ``FakeTerminalAuthRunner`` that did not start the program.
private enum FakeRunnerError: Error, Equatable {
    /// The program did not start.
    case notStarted
}

/// A runner that stands in for the interactive terminal of a host.
///
/// The runner records the arguments and the environment of each call, waits
/// at its gate when it has one, and then gives its outcome.
private final class FakeTerminalAuthRunner: TerminalAuthRunner {
    /// The arguments and the environment of one call.
    struct Call: Equatable {
        /// The arguments that the call got.
        let arguments: [String]

        /// The environment that the call got.
        let environment: [String: String]
    }

    /// The outcome of each call: an exit status, or an error.
    private let outcome: Result<Int32?, FakeRunnerError>

    /// The gate that must open before each call gives its outcome, or `nil`
    /// to give the outcome at once.
    private let gate: UpdateGate?

    /// The calls that the runner got, in arrival order.
    private let recorded = Mutex<[Call]>([])

    /// Makes a runner.
    ///
    /// - Parameters:
    ///   - outcome: The outcome of each call.
    ///   - gate: The gate that must open before each call gives its outcome,
    ///     or `nil` to give the outcome at once.
    init(outcome: Result<Int32?, FakeRunnerError>, gate: UpdateGate? = nil) {
        self.outcome = outcome
        self.gate = gate
    }

    /// The calls that the runner got, in arrival order.
    var calls: [Call] {
        recorded.withLock { $0 }
    }

    /// Records the call, waits at the gate, and gives the outcome.
    ///
    /// - Parameters:
    ///   - arguments: The arguments to append to the agent command.
    ///   - environment: The variables to apply over the launch environment.
    /// - Returns: The exit status of the outcome.
    /// - Throws: The error of the outcome.
    func runTerminalAuth(arguments: [String], environment: [String: String]) async throws -> Int32? {
        recorded.withLock { $0.append(Call(arguments: arguments, environment: environment)) }
        await gate?.wait()
        return try outcome.get()
    }
}

/// The terminal auth tests of the connection model, in one suite so that
/// `swift test --filter ConnectionModelTerminalAuthTests` selects them.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionModelTerminalAuthTests {
    // MARK: - Success

    @Test func aZeroExitRequiresAReconnect() async throws {
        let connected = try await initializedModel()
        let runner = FakeTerminalAuthRunner(outcome: .success(0))

        try await connected.model.loginWithTerminal(InitializeFixtures.terminalMethodId, runner: runner)

        #expect(connected.model.authState == .reconnectRequired(InitializeFixtures.terminalMethodId))
        // A second initialize makes a round trip after the terminal login,
        // so a request that went out would be in the record before its
        // answer.
        _ = try await connected.model.initialize(TerminalAuthFixtures.terminalInitializeRequest())
        #expect(connected.receivedMethods == [ClientRequestSpan.Method.initialize, ClientRequestSpan.Method.initialize])
    }

    @Test func theNextInitializeAfterAReconnectGivesAuthenticated() async throws {
        let connected = try await initializedModel()
        let runner = FakeTerminalAuthRunner(outcome: .success(0))
        try await connected.model.loginWithTerminal(InitializeFixtures.terminalMethodId, runner: runner)

        let reconnected = await connect(connected.model)
        _ = try await reconnected.model.initialize(TerminalAuthFixtures.terminalInitializeRequest())

        #expect(reconnected.model.authState == .authenticated(InitializeFixtures.terminalMethodId))
    }

    @Test func theRunnerGetsTheArgsAndTheEnvOfTheMethod() async throws {
        let connected = try await initializedModel()
        let runner = FakeTerminalAuthRunner(outcome: .success(0))

        try await connected.model.loginWithTerminal(InitializeFixtures.terminalMethodId, runner: runner)

        let expected = FakeTerminalAuthRunner.Call(
            arguments: TerminalAuthFixtures.arguments,
            environment: [TerminalAuthFixtures.environmentName: TerminalAuthFixtures.environmentValue]
        )
        #expect(runner.calls == [expected])
    }

    @Test func aTerminalLoginWithNoOpenConnectionRunsTheMethod() async throws {
        let connected = try await initializedModel()
        try await connected.closeAgentEnd()
        let runner = FakeTerminalAuthRunner(outcome: .success(0))

        try await connected.model.loginWithTerminal(InitializeFixtures.terminalMethodId, runner: runner)

        #expect(runner.calls.count == 1)
        #expect(connected.model.authState == .reconnectRequired(InitializeFixtures.terminalMethodId))
    }

    // MARK: - Failure

    @Test func aNonZeroExitGivesFailedAndThrows() async throws {
        let connected = try await initializedModel()
        let exitStatus = TerminalAuthFixtures.failureExitStatus
        let runner = FakeTerminalAuthRunner(outcome: .success(exitStatus))

        await #expect(throws: ConnectionModelError.terminalAuthFailed(exitStatus: exitStatus)) {
            try await connected.model.loginWithTerminal(InitializeFixtures.terminalMethodId, runner: runner)
        }

        let expected = TerminalAuthFixtures.failure(exitStatus: exitStatus, message: nil)
        #expect(connected.model.authState == .failed(expected))
    }

    @Test func anEndWithNoExitStatusGivesFailed() async throws {
        let connected = try await initializedModel()
        let runner = FakeTerminalAuthRunner(outcome: .success(nil))

        await #expect(throws: ConnectionModelError.terminalAuthFailed(exitStatus: nil)) {
            try await connected.model.loginWithTerminal(InitializeFixtures.terminalMethodId, runner: runner)
        }

        #expect(connected.model.authState == .failed(TerminalAuthFixtures.failure(exitStatus: nil, message: nil)))
    }

    @Test func aRunnerErrorGivesFailedAndThrowsTheError() async throws {
        let connected = try await initializedModel()
        let runner = FakeTerminalAuthRunner(outcome: .failure(.notStarted))

        await #expect(throws: FakeRunnerError.notStarted) {
            try await connected.model.loginWithTerminal(InitializeFixtures.terminalMethodId, runner: runner)
        }

        let expected = TerminalAuthFixtures.failure(
            exitStatus: nil,
            message: String(describing: FakeRunnerError.notStarted)
        )
        #expect(connected.model.authState == .failed(expected))
    }

    @Test func aCancelGivesFailed() async throws {
        let connected = try await initializedModel()
        let gate = UpdateGate()
        let runner = FakeTerminalAuthRunner(outcome: .success(0), gate: gate)
        let model = connected.model
        let login = Task {
            try await model.loginWithTerminal(InitializeFixtures.terminalMethodId, runner: runner)
        }
        try await waitUntil { !runner.calls.isEmpty }

        login.cancel()
        gate.open()

        await #expect(throws: CancellationError.self) {
            try await login.value
        }
        let expected = TerminalAuthFixtures.failure(
            exitStatus: nil,
            message: String(describing: CancellationError())
        )
        #expect(model.authState == .failed(expected))
    }

    // MARK: - Refusal

    @Test func noTerminalCapabilityDoesNotCallTheRunner() async throws {
        let connected = await connect()
        try await connected.initialize()
        let runner = FakeTerminalAuthRunner(outcome: .success(0))

        await #expect(throws: ConnectionModelError.unsupported(method: ConnectionModelError.terminalAuthOperation)) {
            try await connected.model.loginWithTerminal(InitializeFixtures.terminalMethodId, runner: runner)
        }

        #expect(runner.calls.isEmpty)
        let expected = TerminalAuthFixtures.unsupportedFailure(of: InitializeFixtures.terminalMethodId)
        #expect(connected.model.authState == .failed(expected))
    }

    @Test func anAgentMethodIdIsNotRunInATerminal() async throws {
        let connected = try await initializedModel()
        let runner = FakeTerminalAuthRunner(outcome: .success(0))

        await #expect(throws: ConnectionModelError.unsupported(method: ConnectionModelError.terminalAuthOperation)) {
            try await connected.model.loginWithTerminal(InitializeFixtures.agentMethodId, runner: runner)
        }

        #expect(runner.calls.isEmpty)
        let expected = TerminalAuthFixtures.unsupportedFailure(of: InitializeFixtures.agentMethodId)
        #expect(connected.model.authState == .failed(expected))
    }

    @Test func anUnsupportedTerminalLoginRecordsTheFailure() async throws {
        let connected = try await initializedModel()
        let runner = FakeTerminalAuthRunner(outcome: .success(0))
        let unlistedMethodId = AuthMethodId(rawValue: "unlisted")

        await #expect(throws: ConnectionModelError.unsupported(method: ConnectionModelError.terminalAuthOperation)) {
            try await connected.model.loginWithTerminal(unlistedMethodId, runner: runner)
        }

        #expect(runner.calls.isEmpty)
        #expect(connected.model.authState == .failed(TerminalAuthFixtures.unsupportedFailure(of: unlistedMethodId)))
    }

    // MARK: - Helpers

    /// Connects a model to a new stub agent that lists the terminal and the
    /// agent auth method.
    ///
    /// - Parameter model: The model to connect. A second call with the same
    ///   model makes the reconnect.
    /// - Returns: The connected model.
    private func connect(_ model: ConnectionModel = ConnectionModel()) async -> ConnectedModel {
        await ConnectedModel(model: model) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: [],
                authMethods: TerminalAuthFixtures.authMethods
            )
        }
    }

    /// Connects a new model, and initializes it with a request that
    /// advertises `auth.terminal`.
    ///
    /// - Returns: The connected and initialized model.
    /// - Throws: The error of the initialize.
    private func initializedModel() async throws -> ConnectedModel {
        let connected = await connect()
        _ = try await connected.model.initialize(TerminalAuthFixtures.terminalInitializeRequest())
        return connected
    }
}
