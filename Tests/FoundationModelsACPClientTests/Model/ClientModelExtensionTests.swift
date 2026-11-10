import FoundationModelsACP
import Observation
import Testing

@testable import FoundationModelsACPClient

// The tests of `ClientModelExtension`. The tests of the connection part add a
// test extension to a `ConnectionModel`, connect the model over
// `InMemoryTransport.pair()` to a `ScriptedStubAgent`, and let the agent side
// send `_test/notify` and call `_test/echo`. The tests of the session part
// give session updates to a `SessionModel` with test extensions, or connect a
// model with test extensions to a `ResumeStubAgent`. No wait reads a clock or
// polls.

/// The notification that the agent sends to the test extensions.
private let notifyMethod = "_test/notify"

/// The request that the agent sends to the test extensions.
private let echoMethod = "_test/echo"

/// The result that the agent sends in the `_sah/graphql/next` of the test
/// of the SAH extension.
private let sahEvent = SAH.GraphQL.ExecutionResult(data: .object(["changes": .string("c-1")]))

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

    /// The session state of the extension. It holds nothing.
    @MainActor
    final class SessionState {}

    /// The text that `_test/echo` adds after the text of the request.
    var suffix = ""

    @MainActor func makeConnectionState() -> ConnectionState {
        ConnectionState()
    }

    @MainActor func makeSessionState(for sessionId: SessionId) -> SessionState {
        SessionState()
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

    /// The session state of the extension. It holds nothing.
    @MainActor
    final class SessionState {}

    @MainActor func makeConnectionState() -> ConnectionState {
        ConnectionState()
    }

    @MainActor func makeSessionState(for sessionId: SessionId) -> SessionState {
        SessionState()
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

    @Test func aHostExtensionAndTheSAHExtensionBothServeTheirNotificationsOnOneConnection() async throws {
        let connected = await ExtensionFixtures.connectWithEcho()
        defer { await connected.model.disconnect() }
        let sahState = try #require(connected.model.extensionState(SAHGraphQLExtension.self))
        let id = SAH.GraphQL.SubscriptionId(rawValue: "subscription-1")
        let (stream, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        try #require(sahState.subscriptions.open(id, continuation))

        try await connected.agentConnection.sendExtensionNotification(
            SAH.GraphQL.Method.next, SAH.GraphQL.NextNotification(subscriptionId: id, payload: sahEvent))
        // The read loop handles the notifications in arrival order, so the
        // `_sah/graphql/next` is handled when the host extension has its note.
        try await ExtensionFixtures.notify(on: connected, "host")
        continuation.finish()

        #expect(await stream.collect().elements == [sahEvent.jsonValue])
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

// MARK: - The session part

/// The kind of the `_` session update that ``StatusExtension`` takes.
private let statusKind = "_test_status"

/// The kind of an `_` session update that no test extension takes.
private let otherKind = "_test_other"

/// The notification that the agent sends to ``StatusExtension`` for one
/// session. It is not a `session/update`.
private let sessionNoteMethod = "_test/session_note"

/// The params of `_test/session_note`.
private struct SessionNote: Codable, Sendable {
    /// The session that the note names.
    let sessionId: SessionId

    /// The text of the note.
    let text: String
}

/// The test extension of the session part: it takes each `_test_status`
/// update, and records each update that it sees in its session state.
private struct StatusExtension: ClientModelExtension {
    /// The connection state of the extension. It holds nothing.
    @MainActor
    final class ConnectionState {}

    /// The observable session state of the extension.
    @MainActor @Observable
    final class SessionState {
        /// The session of the state.
        let sessionId: SessionId

        /// The text of each `_test_status` update and of each
        /// `_test/session_note`, in arrival order.
        var statuses: [String] = []

        /// Each session update that the extension saw, in order.
        var seen: [SessionUpdate] = []

        /// The `mcpServers` field of each request that started the session,
        /// in order.
        var startedServerLists: [[MCPServer]?] = []

        /// Makes the state of one session.
        ///
        /// - Parameter sessionId: The session of the state.
        init(sessionId: SessionId) {
            self.sessionId = sessionId
        }
    }

    @MainActor func makeConnectionState() -> ConnectionState {
        ConnectionState()
    }

    @MainActor func makeSessionState(for sessionId: SessionId) -> SessionState {
        SessionState(sessionId: sessionId)
    }

    func registerHandlers(
        into handlers: inout ClientModelExtensionHandlers,
        context: ClientModelExtensionContext<Self>
    ) {
        handlers.registerNotification(sessionNoteMethod, params: SessionNote.self) { note in
            await MainActor.run { context.sessionState(for: note.sessionId)?.statuses.append(note.text) }
        }
    }

    @MainActor func apply(_ update: SessionUpdate, to state: SessionState) -> Bool {
        state.seen.append(update)
        guard let text = SessionExtensionFixtures.statusText(of: update) else { return false }
        state.statuses.append(text)
        return true
    }

    @MainActor func didStartSession(state: SessionState, mcpServers request: any MCPServerListRequest) {
        state.startedServerLists.append(request.mcpServers)
    }
}

/// A second test extension of the session part: it records each update that
/// it sees, and it also takes each `_test_status` update.
private struct RecordingExtension: ClientModelExtension {
    /// The connection state of the extension. It holds nothing.
    @MainActor
    final class ConnectionState {}

    /// The session state of the extension.
    @MainActor
    final class SessionState {
        /// Each session update that the extension saw, in order.
        var seen: [SessionUpdate] = []
    }

    @MainActor func makeConnectionState() -> ConnectionState {
        ConnectionState()
    }

    @MainActor func makeSessionState(for sessionId: SessionId) -> SessionState {
        SessionState()
    }

    func registerHandlers(
        into handlers: inout ClientModelExtensionHandlers,
        context: ClientModelExtensionContext<Self>
    ) {}

    @MainActor func apply(_ update: SessionUpdate, to state: SessionState) -> Bool {
        state.seen.append(update)
        return SessionExtensionFixtures.statusText(of: update) != nil
    }
}

/// The shared setup of the session part.
@MainActor
private enum SessionExtensionFixtures {
    /// The name of the MCP server of ``configServerStatus``.
    nonisolated static let configServerName = "search"

    /// An `_mcp_server_status` update of a server that only the
    /// configuration of the agent gives. The built-in MCP server extension
    /// takes it.
    nonisolated static let configServerStatus = SessionUpdate.unknown(
        "_mcp_server_status",
        .object([
            "name": .string(configServerName),
            "origin": .string("config"),
            "status": .string("connected"),
        ])
    )

    /// Makes an `_` session update with a text.
    ///
    /// - Parameters:
    ///   - kind: The wire kind of the update.
    ///   - text: The text of the update.
    /// - Returns: The update.
    nonisolated static func update(_ kind: String = statusKind, text: String) -> SessionUpdate {
        .unknown(kind, .object(["text": .string(text)]))
    }

    /// Gives the text of a `_test_status` update.
    ///
    /// - Parameter update: The update to read.
    /// - Returns: The text, or `nil` when the update is not a `_test_status`
    ///   update with a text.
    nonisolated static func statusText(of update: SessionUpdate) -> String? {
        guard case .unknown(let kind, .object(let members)) = update, kind == statusKind,
            case .string(let text)? = members["text"]
        else { return nil }
        return text
    }

    /// Makes a preview model with the test extensions, which applies each
    /// update at once.
    ///
    /// - Parameter extensions: The extensions, in order.
    /// - Returns: The model.
    static func model(with extensions: [any ClientModelExtension] = [StatusExtension()]) -> SessionModel {
        SessionModel.preview(sessionId: testSession, extensions: extensions)
    }

    /// Gives the ``StatusExtension`` state of a model.
    ///
    /// - Parameter model: The model.
    /// - Returns: The session state.
    /// - Throws: An error of `#require` when the model has no state of the
    ///   extension.
    static func status(of model: SessionModel) throws -> StatusExtension.SessionState {
        try #require(model.extensionState(StatusExtension.self))
    }

    /// Connects a model with one ``StatusExtension`` to a resume stub agent,
    /// and opens the root session.
    ///
    /// - Returns: The connection.
    /// - Throws: The error of `initialize` or of `session/new`.
    static func connect() async throws -> ResumeConnection {
        try await ResumeConnection.make(extensions: [StatusExtension()])
    }

    /// Sends a `_test_status` update to the root session from the agent side,
    /// and waits until the session state of the root holds its text.
    ///
    /// - Parameters:
    ///   - connected: The connection.
    ///   - text: The text of the update.
    /// - Returns: The session state of the root.
    /// - Throws: ``WaitEndedOnFailure`` when the root closed first.
    @discardableResult
    static func sendStatus(
        on connected: ResumeConnection,
        _ text: String
    ) async throws -> StatusExtension.SessionState {
        let state = try status(of: connected.root)
        try await connected.agent.send(update(text: text))
        try await waitForObservation { state.statuses.contains(text) } orFailWhen: { connected.root.isClosed }
        return state
    }
}

// The session part is a suite inside `ClientModelExtensionTests`, so
// `swift test --filter ClientModelExtensionTests` selects both parts.
extension ClientModelExtensionTests {
    @MainActor
    @Suite("ClientModelExtension, the session part")
    struct SessionPart {
        // MARK: - Apply

        @Test func aTakenUpdateChangesTheSessionState() throws {
            let model = SessionExtensionFixtures.model()

            model.apply(SessionExtensionFixtures.update(text: "busy"))

            #expect(try SessionExtensionFixtures.status(of: model).statuses == ["busy"])
        }

        @Test func aTakenUpdateAddsNoTranscriptEntry() {
            let model = SessionExtensionFixtures.model()

            model.apply(SessionExtensionFixtures.update(text: "busy"))

            #expect(model.transcript.isEmpty)
        }

        @Test func anUnderscoreUpdateThatNoExtensionTakesBecomesAnUnknownEntry() {
            let model = SessionExtensionFixtures.model()

            model.apply(SessionExtensionFixtures.update(otherKind, text: "idle"))

            #expect(model.transcript.first?.unknown?.type == otherKind)
        }

        @Test func theFirstExtensionThatTakesTheUpdateKeepsItFromTheLaterExtension() throws {
            let model = SessionExtensionFixtures.model(with: [StatusExtension(), RecordingExtension()])

            model.apply(SessionExtensionFixtures.update(text: "busy"))

            #expect(try #require(model.extensionState(RecordingExtension.self)).seen.isEmpty)
        }

        @Test func aLaterExtensionDoesNotGetAnUpdateThatAnEarlierExtensionTook() throws {
            let model = SessionExtensionFixtures.model(with: [RecordingExtension(), StatusExtension()])

            model.apply(SessionExtensionFixtures.update(text: "busy"))

            #expect(try SessionExtensionFixtures.status(of: model).seen.isEmpty)
        }

        @Test func theExtensionSeesAStandardUpdate() throws {
            let model = SessionExtensionFixtures.model()

            model.apply(userChunk(text: "Hello"))

            #expect(try SessionExtensionFixtures.status(of: model).seen == [userChunk(text: "Hello")])
        }

        @Test func aStandardUpdateThatTheExtensionDoesNotTakeAddsItsEntry() {
            let model = SessionExtensionFixtures.model()

            model.apply(userChunk(text: "Hello"))

            #expect(model.transcript.map(\.id) == [.wire(.userMessage(MessageId(rawValue: "user-1")))])
        }

        @Test func chunksBeforeAndAfterATakenUpdateKeepTheArrivalOrder() throws {
            let model = SessionModel(
                sessionId: testSession,
                requestSender: FakeSessionRequestSender(),
                coalescingCadence: SessionModelFixtures.bufferedCadence,
                clock: ManualClock(),
                extensionFactories: [OpenedSessionExtension.factory(for: StatusExtension())]
            )
            let arrivals = [
                agentChunk(text: "before"), SessionExtensionFixtures.update(text: "busy"), agentChunk(text: "after"),
            ]

            model.applyEach(arrivals)
            model.flushPendingChunks()

            #expect(try SessionExtensionFixtures.status(of: model).seen == arrivals)
        }

        @Test func eachSessionModelHasItsOwnSessionState() throws {
            let first = SessionExtensionFixtures.model()
            let second = SessionExtensionFixtures.model()

            #expect(try SessionExtensionFixtures.status(of: first) !== SessionExtensionFixtures.status(of: second))
        }

        @Test func extensionStateIsNilForAnExtensionThatTheSessionDoesNotHave() {
            let model = SessionExtensionFixtures.model()

            #expect(model.extensionState(RecordingExtension.self) == nil)
        }

        // MARK: - Preview

        @Test func anUpdateItemOfAPreviewSetsTheSessionState() throws {
            let model = SessionModel.preview(
                transcript: [.update(SessionExtensionFixtures.update(text: "sample"))],
                extensions: [StatusExtension()]
            )

            #expect(try SessionExtensionFixtures.status(of: model).statuses == ["sample"])
        }

        // MARK: - Connection

        @Test func theRootSessionGetsASessionStateForItsSession() async throws {
            let connected = try await SessionExtensionFixtures.connect()
            defer { await connected.model.disconnect() }

            #expect(try SessionExtensionFixtures.status(of: connected.root).sessionId == testSession)
        }

        @Test func aChildSessionGetsASessionStateForItsSession() async throws {
            let connected = try await SessionExtensionFixtures.connect()
            defer { await connected.model.disconnect() }

            let child = try await connected.announce(try snapshot(firstChild), child: firstChild)

            #expect(try SessionExtensionFixtures.status(of: child).sessionId == firstChild)
        }

        @Test func aChildSessionDoesNotShareTheStateOfItsParent() async throws {
            let connected = try await SessionExtensionFixtures.connect()
            defer { await connected.model.disconnect() }

            let child = try await connected.announce(try snapshot(firstChild), child: firstChild)

            let rootState = try SessionExtensionFixtures.status(of: connected.root)
            #expect(try SessionExtensionFixtures.status(of: child) !== rootState)
        }

        @Test func aTakenUpdateOfTheAgentChangesTheSessionState() async throws {
            let connected = try await SessionExtensionFixtures.connect()
            defer { await connected.model.disconnect() }

            let state = try await SessionExtensionFixtures.sendStatus(on: connected, "busy")

            #expect(state.statuses == ["busy"])
        }

        @Test func didStartSessionGetsTheServersOfSessionNew() async throws {
            let connected = try await SessionExtensionFixtures.connect()
            defer { await connected.model.disconnect() }

            #expect(try SessionExtensionFixtures.status(of: connected.root).startedServerLists == [nil])
        }

        @Test func didStartSessionGetsTheServersOfSessionResume() async throws {
            let connected = try await SessionExtensionFixtures.connect()
            defer { await connected.model.disconnect() }

            _ = try await connected.resume(replayFrom: nil)

            #expect(try SessionExtensionFixtures.status(of: connected.root).startedServerLists == [nil, nil])
        }

        @Test func aNotificationHandlerFindsTheSessionStateOfItsSession() async throws {
            let connected = try await SessionExtensionFixtures.connect()
            defer { await connected.model.disconnect() }
            let state = try SessionExtensionFixtures.status(of: connected.root)

            try await connected.connected.agentConnection.sendExtensionNotification(
                sessionNoteMethod, SessionNote(sessionId: testSession, text: "noted"))

            try await waitForObservation { state.statuses == ["noted"] } orFailWhen: { connected.root.isClosed }
        }

        // MARK: - Replay

        @Test func aReplayWithHistoryMakesANewSessionState() async throws {
            let connected = try await SessionExtensionFixtures.connect()
            defer { await connected.model.disconnect() }
            let before = try await SessionExtensionFixtures.sendStatus(on: connected, "before")

            _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)

            #expect(try SessionExtensionFixtures.status(of: connected.root) !== before)
        }

        @Test func aResumeWithNoHistoryKeepsTheSessionState() async throws {
            let connected = try await SessionExtensionFixtures.connect()
            defer { await connected.model.disconnect() }
            let before = try SessionExtensionFixtures.status(of: connected.root)

            _ = try await connected.resume(replayFrom: nil)

            #expect(try SessionExtensionFixtures.status(of: connected.root) === before)
        }

        @Test func aFailedReplayGivesBackTheEarlierSessionState() async throws {
            let connected = try await SessionExtensionFixtures.connect()
            defer { await connected.model.disconnect() }
            let before = try await SessionExtensionFixtures.sendStatus(on: connected, "before")
            connected.agent.setReplay { connection in
                let update = SessionExtensionFixtures.update(text: "replayed")
                try await connection.sessionUpdate(UpdateSessionNotification(sessionId: testSession, update: update))
            }
            connected.agent.setResumeError(RequestError.internalError(detail: "no"))

            await #expect(throws: (any Error).self) {
                _ = try await connected.resume(replayFrom: SessionModelFixtures.replayFromStart)
            }

            #expect(try SessionExtensionFixtures.status(of: connected.root) === before)
        }

        // MARK: - Built-in extensions

        @Test func aHostExtensionOfAPreviewDoesNotGetAnUpdateThatABuiltInExtensionTook() throws {
            let model = SessionExtensionFixtures.model(with: [RecordingExtension()])

            model.apply(SessionExtensionFixtures.configServerStatus)

            #expect(try #require(model.extensionState(RecordingExtension.self)).seen.isEmpty)
        }

        @Test func aHostExtensionOfTheConnectionDoesNotGetAnUpdateThatABuiltInExtensionTook() async throws {
            let connected = try await ResumeConnection.make(extensions: [RecordingExtension()])
            defer { await connected.model.disconnect() }
            let root = connected.root

            try await connected.agent.send(SessionExtensionFixtures.configServerStatus)
            try await waitForObservation {
                root.mcpServers.contains { $0.name == SessionExtensionFixtures.configServerName }
            } orFailWhen: {
                root.isClosed
            }

            let seen = try #require(root.extensionState(RecordingExtension.self)).seen
            #expect(!seen.contains(SessionExtensionFixtures.configServerStatus))
        }
    }
}
