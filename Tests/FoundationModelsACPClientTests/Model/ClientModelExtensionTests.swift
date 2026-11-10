import FoundationModelsACP
import Observation
import Testing

@testable import FoundationModelsACPClient

// The tests of the connection part of `ClientModelExtension`. Each test adds a
// test extension to a `ConnectionModel`, connects the model over
// `InMemoryTransport.pair()` to a `ScriptedStubAgent`, and lets the agent side
// send `_test/notify` and call `_test/echo`. No wait reads a clock or polls.

/// The notification that the agent sends to the test extensions.
private let notifyMethod = "_test/notify"

/// The request that the agent sends to the test extensions.
private let echoMethod = "_test/echo"

/// The params of `_test/notify` and of `_test/echo`, and the result of
/// `_test/echo`.
private struct TestNote: Codable, Equatable, Sendable {
    /// The text of the note.
    let text: String
}

/// The test extension: it records each `_test/notify` in its connection
/// state, and answers `_test/echo` with the text and its suffix.
private struct EchoExtension: ClientModelExtension {
    /// The observable connection state of the test extension.
    @MainActor @Observable
    final class ConnectionState {
        /// The text of each `_test/notify`, in arrival order.
        var notes: [String] = []

        /// The agent name of each `initialize` response, in order.
        var initializedAgentNames: [String] = []

        /// The number of calls of `didClose(state:)`.
        var closeCount = 0
    }

    /// The text that `_test/echo` adds after the text of the request.
    var suffix = ""

    @MainActor func makeConnectionState() -> ConnectionState {
        ConnectionState()
    }

    func registerHandlers(
        into handlers: inout ClientModelExtensionHandlers,
        context: ClientModelExtensionContext<Self>
    ) {
        handlers.registerNotification(notifyMethod, params: TestNote.self) { note in
            await MainActor.run { context.connectionState.notes.append(note.text) }
        }
        let suffix = suffix
        handlers.registerMethod(echoMethod, params: TestNote.self) { note in
            TestNote(text: note.text + suffix)
        }
    }

    @MainActor func didInitialize(_ response: InitializeResponse, state: ConnectionState) {
        state.initializedAgentNames.append(response.info.name)
    }

    @MainActor func didClose(state: ConnectionState) {
        state.closeCount += 1
    }
}

/// A second test extension: it answers `_test/echo` with the text in upper
/// case, so a test can tell which extension served the request.
private struct ShoutExtension: ClientModelExtension {
    /// The connection state of the extension. It holds nothing.
    @MainActor
    final class ConnectionState {}

    @MainActor func makeConnectionState() -> ConnectionState {
        ConnectionState()
    }

    func registerHandlers(
        into handlers: inout ClientModelExtensionHandlers,
        context: ClientModelExtensionContext<Self>
    ) {
        handlers.registerMethod(echoMethod, params: TestNote.self) { note in
            TestNote(text: note.text.uppercased())
        }
    }
}

/// A `Client` in front of the router that forwards each call, and gives the
/// `extensionHandlers` of the router as its own.
private struct ExtensionForwardingClient: Client {
    /// The router that this client stands in front of.
    let router: any Client

    var extensionHandlers: ExtensionHandlers {
        router.extensionHandlers
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        await router.sessionUpdate(notification)
    }

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        try await router.requestPermission(params)
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        try await router.createElicitation(params)
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        await router.elicitationComplete(notification)
    }
}

/// The shared setup of the extension tests.
@MainActor
private enum ExtensionFixtures {
    /// Connects `model` to a new stub agent.
    ///
    /// - Parameters:
    ///   - model: The model to connect.
    ///   - wrap: Builds the served `Client` from the router of the model.
    /// - Returns: The connected model.
    static func connect(
        _ model: ConnectionModel,
        client wrap: @escaping @Sendable @MainActor (any Client) -> any Client = { $0 }
    ) async -> ConnectedModel {
        await ConnectedModel(model: model, client: wrap) { connection in
            ScriptedStubAgent(connection: connection, session: testSession, script: [])
        }
    }

    /// Makes a model with one ``EchoExtension``, and connects it.
    ///
    /// - Parameter logLines: Gets each diagnostic of the model.
    /// - Returns: The connected model.
    static func connectWithEcho(logLines: ThreadSafeBuffer<String> = ThreadSafeBuffer()) async -> ConnectedModel {
        let model = ConnectionModel(logger: ACPLogger { logLines.append($0) })
        model.addExtension(EchoExtension())
        return await connect(model)
    }

    /// Calls `_test/echo` from the agent side.
    ///
    /// - Parameters:
    ///   - connected: The connected model.
    ///   - text: The text of the request.
    /// - Returns: The result that the client gave.
    /// - Throws: The error of the call.
    static func echo(on connected: ConnectedModel, _ text: String) async throws -> TestNote {
        try await connected.agentConnection.callExtensionMethod(
            echoMethod, TestNote(text: text), returning: TestNote.self)
    }

    /// Sends `_test/notify` from the agent side, and waits until the
    /// ``EchoExtension`` state of the model holds the text.
    ///
    /// - Parameters:
    ///   - connected: The connected model.
    ///   - text: The text of the notification.
    /// - Returns: The state that got the notification.
    /// - Throws: ``WaitEndedOnFailure`` when the connection closed first.
    @discardableResult
    static func notify(on connected: ConnectedModel, _ text: String) async throws -> EchoExtension.ConnectionState {
        let state = try #require(connected.model.extensionState(EchoExtension.self))
        try await connected.agentConnection.sendExtensionNotification(notifyMethod, TestNote(text: text))
        try await waitUntil { state.notes.contains(text) } orFailWhen: { connected.isConnectionClosed }
        return state
    }

    /// The count of the log lines that hold `marker`.
    ///
    /// - Parameters:
    ///   - logLines: The log lines of the model.
    ///   - marker: The text to find.
    /// - Returns: The count of the lines with `marker`.
    nonisolated static func count(of marker: String, in logLines: ThreadSafeBuffer<String>) -> Int {
        logLines.elements.filter { $0.contains(marker) }.count
    }
}

@MainActor
@Suite("ClientModelExtension, the connection part")
struct ClientModelExtensionTests {
    @Test func aNotificationOfTheAgentChangesTheObservableConnectionState() async throws {
        let connected = await ExtensionFixtures.connectWithEcho()
        defer { await connected.model.disconnect() }

        let state = try await ExtensionFixtures.notify(on: connected, "one")

        #expect(state.notes == ["one"])
    }

    @Test func theExtensionServesARequestOfTheAgent() async throws {
        let connected = await ExtensionFixtures.connectWithEcho()
        defer { await connected.model.disconnect() }

        let result = try await ExtensionFixtures.echo(on: connected, "ping")

        #expect(result == TestNote(text: "ping"))
    }

    @Test func didInitializeGetsTheInitializeResponse() async throws {
        let connected = await ExtensionFixtures.connectWithEcho()
        defer { await connected.model.disconnect() }

        try await connected.initialize()

        #expect(connected.model.extensionState(EchoExtension.self)?.initializedAgentNames == ["stub-agent"])
    }

    @Test func didCloseRunsOneTimeWhenTheHostDisconnects() async throws {
        let connected = await ExtensionFixtures.connectWithEcho()
        let state = try #require(connected.model.extensionState(EchoExtension.self))

        await connected.model.disconnect()

        #expect(state.closeCount == 1)
    }

    @Test func didCloseRunsOneTimeWhenTheAgentClosesItsEnd() async throws {
        let connected = await ExtensionFixtures.connectWithEcho()
        let state = try #require(connected.model.extensionState(EchoExtension.self))

        try await connected.closeAgentEnd()

        #expect(state.closeCount == 1)
    }

    @Test func didCloseRunsWhenANewConnectReplacesTheOpenConnection() async throws {
        let model = ConnectionModel()
        model.addExtension(EchoExtension())
        let first = await ExtensionFixtures.connect(model)
        let state = try #require(model.extensionState(EchoExtension.self))

        let second = await ExtensionFixtures.connect(model)
        defer { await second.model.disconnect() }
        await first.agentConnection.close()

        try await waitUntil { state.closeCount == 1 } orFailWhen: { second.isConnectionClosed }
    }

    @Test func addExtensionWhileConnectedLogsOneDiagnostic() async throws {
        let logLines = ThreadSafeBuffer<String>()
        let connected = await ExtensionFixtures.connect(ConnectionModel(logger: ACPLogger { logLines.append($0) }))
        defer { await connected.model.disconnect() }

        connected.model.addExtension(EchoExtension())

        #expect(ExtensionFixtures.count(of: "takes effect at the next connect", in: logLines) == 1)
    }

    @Test func addExtensionWhileConnectedDoesNotServeTheOpenConnection() async throws {
        let connected = await ExtensionFixtures.connect(ConnectionModel())
        defer { await connected.model.disconnect() }

        connected.model.addExtension(EchoExtension())

        await #expect(throws: RequestError.self) {
            _ = try await ExtensionFixtures.echo(on: connected, "ping")
        }
    }

    @Test func addExtensionWhileConnectedTakesEffectAtTheNextConnect() async throws {
        let model = ConnectionModel()
        let first = await ExtensionFixtures.connect(model)
        model.addExtension(EchoExtension())
        await first.model.disconnect()

        let second = await ExtensionFixtures.connect(model)
        defer { await second.model.disconnect() }

        #expect(try await ExtensionFixtures.echo(on: second, "ping") == TestNote(text: "ping"))
    }

    @Test func extensionStateIsNilBeforeTheFirstConnect() {
        let model = ConnectionModel()
        model.addExtension(EchoExtension())

        #expect(model.extensionState(EchoExtension.self) == nil)
    }

    @Test func eachConnectMakesANewConnectionState() async throws {
        let model = ConnectionModel()
        model.addExtension(EchoExtension())
        let first = await ExtensionFixtures.connect(model)
        let firstState = try #require(model.extensionState(EchoExtension.self))
        await first.model.disconnect()

        let second = await ExtensionFixtures.connect(model)
        defer { await second.model.disconnect() }

        let secondState = try #require(model.extensionState(EchoExtension.self))
        #expect(secondState !== firstState)
    }

    @Test func aWrappingClientThatForwardsTheExtensionHandlersKeepsTheNotifications() async throws {
        let model = ConnectionModel()
        model.addExtension(EchoExtension())
        let connected = await ExtensionFixtures.connect(model) { ExtensionForwardingClient(router: $0) }
        defer { await connected.model.disconnect() }

        let state = try await ExtensionFixtures.notify(on: connected, "wrapped")

        #expect(state.notes == ["wrapped"])
    }

    @Test func theLaterExtensionWinsAMethodThatTwoExtensionsRegister() async throws {
        let model = ConnectionModel()
        model.addExtension(EchoExtension())
        model.addExtension(ShoutExtension())
        let connected = await ExtensionFixtures.connect(model)
        defer { await connected.model.disconnect() }

        #expect(try await ExtensionFixtures.echo(on: connected, "ping") == TestNote(text: "PING"))
    }

    @Test func aMethodThatTwoExtensionsRegisterLogsOneDiagnostic() async throws {
        let logLines = ThreadSafeBuffer<String>()
        let model = ConnectionModel(logger: ACPLogger { logLines.append($0) })
        model.addExtension(EchoExtension())
        model.addExtension(ShoutExtension())

        let connected = await ExtensionFixtures.connect(model)
        defer { await connected.model.disconnect() }

        #expect(ExtensionFixtures.count(of: "\"\(echoMethod)\" is registered again", in: logLines) == 1)
    }

    @Test func aSecondExtensionOfTheSameTypeReplacesTheFirst() async throws {
        let model = ConnectionModel()
        model.addExtension(EchoExtension(suffix: "-a"))
        model.addExtension(EchoExtension(suffix: "-b"))
        let connected = await ExtensionFixtures.connect(model)
        defer { await connected.model.disconnect() }

        #expect(try await ExtensionFixtures.echo(on: connected, "ping") == TestNote(text: "ping-b"))
    }
}

@Suite("ClientModelExtensionHandlers")
struct ClientModelExtensionHandlersTests {
    @Test func aNotificationThatIsRegisteredAgainLogsOneDiagnostic() {
        let logLines = ThreadSafeBuffer<String>()
        var handlers = ClientModelExtensionHandlers(logger: ACPLogger { logLines.append($0) })

        handlers.registerNotification(notifyMethod, params: TestNote.self) { _ in }
        handlers.registerNotification(notifyMethod, params: TestNote.self) { _ in }

        #expect(ExtensionFixtures.count(of: "\"\(notifyMethod)\" is registered again", in: logLines) == 1)
    }

    @Test func aMethodAndANotificationOfOneNameLogNoDiagnostic() {
        let logLines = ThreadSafeBuffer<String>()
        var handlers = ClientModelExtensionHandlers(logger: ACPLogger { logLines.append($0) })

        handlers.registerMethod(echoMethod, params: TestNote.self) { $0 }
        handlers.registerNotification(echoMethod, params: TestNote.self) { _ in }

        #expect(logLines.elements.isEmpty)
    }
}
