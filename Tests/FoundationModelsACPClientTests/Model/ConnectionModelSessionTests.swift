import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the session factory of `ConnectionModel`: `newSession(_:)`,
// the request sender that it gives each session model, and `close(_:)`.
//
// `ConnectedModel` gives the real ACP wire, with a `ScriptedStubAgent` on the
// agent end. The stub sends its `newSessionScript` before it answers
// `session/new`, so the updates are on the wire before the model knows the
// session id.

/// The fixtures of the session factory tests.
private enum SessionFactoryFixtures {
    /// The new-session request that each test sends.
    static let newSessionRequest = NewSessionRequest(cwd: AbsolutePath(rawValue: "/"))

    /// The update limit of a connection that keeps one update for a session
    /// with no subscriber.
    static let oneUpdateLimit = 1

    /// The session limit of a connection that keeps the updates of one
    /// session with no subscriber.
    static let oneSessionLimit = 1

    /// The limits of a connection that keeps one update for one session.
    static let oneUpdateBuffer = SessionUpdateBufferLimits(
        maximumUpdatesPerSession: oneUpdateLimit,
        maximumSessions: oneSessionLimit
    )

    /// Two agent messages, which give two transcript entries.
    static let twoMessages = [
        agentChunk(text: "first", message: "agent-1"),
        agentChunk(text: "second", message: "agent-2"),
    ]

    /// The command list that the agent answers `session/new` with.
    static let commands = [AvailableCommand(description: "Make a plan", name: "plan")]

    /// The request that changes the mode of the test session.
    static let setModeRequest = SetSessionConfigOptionRequest(
        configId: SessionConfigId(rawValue: "mode"),
        sessionId: testSession,
        value: .id(SessionConfigValueId(rawValue: "fast"))
    )

    /// The error of a close that the agent does not advertise.
    static let closeUnsupported = ConnectionModelError.unsupported(method: ClientRequestSpan.Method.closeSession)

    /// The error that the agent refuses a close with.
    static let closeRefusal = RequestError.invalidParams

    /// Connects a model that applies each chunk at once to a stub agent.
    ///
    /// - Parameters:
    ///   - capabilities: The capabilities the agent answers `initialize`
    ///     with.
    ///   - bufferLimits: The limits on the updates that the connection keeps
    ///     for a session with no subscriber.
    ///   - newSessionScript: The updates the agent sends before its
    ///     `session/new` answer.
    ///   - newSessionCommands: The command list of the `session/new` answer.
    ///   - closeSessionError: The error the agent refuses each close with, or
    ///     `nil` to accept each close.
    /// - Returns: The connected model, after `initialize`.
    /// - Throws: Whatever `initialize` threw.
    @MainActor
    static func connect(
        capabilities: AgentCapabilities = InitializeFixtures.baselineCapabilities,
        bufferLimits: SessionUpdateBufferLimits = .default,
        newSessionScript: [SessionUpdate] = [],
        newSessionCommands: [AvailableCommand]? = nil,
        closeSessionError: RequestError? = nil
    ) async throws -> ConnectedModel {
        let connected = await ConnectedModel(
            model: ConnectionModel(coalescingCadence: .zero),
            bufferLimits: bufferLimits
        ) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: [],
                closeSessionError: closeSessionError,
                newSessionScript: newSessionScript,
                newSessionCommands: newSessionCommands,
                capabilities: capabilities
            )
        }
        try await connected.initialize()
        return connected
    }
}

/// The session factory tests of the connection model, in one suite so that
/// `swift test --filter ConnectionModelSessionTests` selects them. A wait for
/// an update that never comes would suspend for ever, so the suite has a time
/// limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionModelSessionTests {
    // MARK: - newSession

    @Test func newSessionRegistersAnOpenModelForTheSessionOfTheAnswer() async throws {
        let connected = try await SessionFactoryFixtures.connect()

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        #expect(session.sessionId == testSession)
        #expect(connected.model.session(for: testSession) === session)
        #expect(!session.isClosed)
    }

    @Test func updatesBeforeTheNewSessionAnswerAreInTheModel() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            newSessionScript: SessionFactoryFixtures.twoMessages
        )

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        try await waitUntil { session.transcript.count == SessionFactoryFixtures.twoMessages.count }
        #expect(session.transcript.map { $0.agentMessage?.content.joinedText } == ["first", "second"])
        #expect(!session.hasMissedUpdates)
    }

    @Test func moreUpdatesThanTheBufferBeforeTheAnswerMarkMissedUpdates() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            bufferLimits: SessionFactoryFixtures.oneUpdateBuffer,
            newSessionScript: SessionFactoryFixtures.twoMessages
        )

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        #expect(session.hasMissedUpdates)
    }

    @Test func anAnswerWithNoCommandListLeavesTheCommandsUnknown() async throws {
        let connected = try await SessionFactoryFixtures.connect()

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        #expect(session.availableCommands == nil)
    }

    @Test func anAnswerWithACommandListSeedsTheCommands() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            newSessionCommands: SessionFactoryFixtures.commands
        )

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        #expect(session.availableCommands == SessionFactoryFixtures.commands)
    }

    @Test func newSessionWithNoConnectionThrowsClosed() async {
        let model = ConnectionModel()

        await #expect(throws: ConnectionError.closed) {
            try await model.newSession(SessionFactoryFixtures.newSessionRequest)
        }
        #expect(model.openSessions.isEmpty)
    }

    // MARK: - The request sender

    @Test func aNewSessionPromptsOverTheConnection() async throws {
        let connected = try await SessionFactoryFixtures.connect()
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        let response = try await session.prompt([textBlock("Hello")])

        #expect(response == testPromptResponse)
        #expect(connected.receivedMethods.last == ClientRequestSpan.Method.prompt)
    }

    @Test func aNewSessionCancelsOverTheConnection() async throws {
        let connected = try await SessionFactoryFixtures.connect()
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        try await session.cancel()

        // A notification has no answer, so the test waits for the record of
        // the agent. The suite time limit stops a wait for a cancel that never
        // arrives.
        try await waitUntil { connected.receivedMethods.contains(ClientRequestSpan.Method.cancelSession) }
    }

    @Test func aNewSessionSetsAConfigOptionOverTheConnection() async throws {
        let connected = try await SessionFactoryFixtures.connect()
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        try await session.setConfigOption(SessionFactoryFixtures.setModeRequest)

        #expect(connected.receivedMethods.last == ScriptedStubAgent.setConfigOptionMethod)
    }

    // MARK: - close

    @Test func closeSendsTheCloseAndClosesTheModel() async throws {
        let connected = try await SessionFactoryFixtures.connect()
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        try await connected.model.close(session)

        #expect(session.isClosed)
        #expect(connected.model.openSessions.isEmpty)
        #expect(connected.receivedMethods.last == ClientRequestSpan.Method.closeSession)
    }

    @Test func aClosedModelKeepsItsTranscript() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            newSessionScript: SessionFactoryFixtures.twoMessages
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)
        try await waitUntil { session.transcript.count == SessionFactoryFixtures.twoMessages.count }

        try await connected.model.close(session)

        #expect(session.transcript.count == SessionFactoryFixtures.twoMessages.count)
    }

    @Test func aCloseThatTheAgentRefusesThrowsItsErrorAndKeepsTheModelOpen() async throws {
        let connected = try await SessionFactoryFixtures.connect(closeSessionError: SessionFactoryFixtures.closeRefusal)
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        await #expect(throws: SessionFactoryFixtures.closeRefusal) {
            try await connected.model.close(session)
        }

        #expect(!session.isClosed)
        #expect(connected.model.session(for: testSession) === session)
    }

    @Test func closeWithNoCapabilityThrowsUnsupportedAndKeepsTheModelOpen() async throws {
        let connected = try await SessionFactoryFixtures.connect(capabilities: AgentCapabilities())
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        await #expect(throws: SessionFactoryFixtures.closeUnsupported) {
            try await connected.model.close(session)
        }
        // A second initialize makes a round trip after the refused close, so
        // a close that went out would be in the record before its answer.
        try await connected.initialize()

        #expect(!connected.receivedMethods.contains(ClientRequestSpan.Method.closeSession))
        #expect(!session.isClosed)
        #expect(connected.model.session(for: testSession) === session)
    }
}
