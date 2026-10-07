import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the session factory of `ConnectionModel`: `newSession(_:)`,
// `resumeSession(_:)`, the request sender that it gives each session model,
// and `close(_:)`.
//
// `ConnectedModel` gives the real ACP wire, with a `ScriptedStubAgent` on the
// agent end. The stub sends its `newSessionScript` before it answers
// `session/new`, so the updates are on the wire before the model knows the
// session id, and its `afterNewSessionScript` after the answer. It sends its
// `resumeSessionScript` as the replay of a `session/resume`, before the
// answer.

/// The fixtures of the session factory tests.
private enum SessionFactoryFixtures {
    /// The working directory of each request that the tests send.
    static let workingDirectory = AbsolutePath(rawValue: "/")

    /// The new-session request that each test sends.
    static let newSessionRequest = NewSessionRequest(cwd: workingDirectory)

    /// The replay cursor that asks for the full retained history.
    static let replayFromStart: ReplayFrom = .start(ReplayFromStart())

    /// The resume request that each test sends: the test session, with a
    /// replay from the start.
    static let resumeRequest = ResumeSessionRequest(
        cwd: workingDirectory,
        sessionId: testSession,
        replayFrom: replayFromStart
    )

    /// One agent message, replayed in two chunks.
    static let chunkedReplay = [
        agentChunk(text: "Hel", message: "agent-1"),
        agentChunk(text: "lo", message: "agent-1"),
    ]

    /// The text of the message of ``chunkedReplay``.
    static let replayedText = "Hello"

    /// The number of resumes in the cancelled-resume test: the cancelled
    /// resume and the resume that runs after it. Each one replays
    /// ``chunkedReplay``.
    static let cancelledAndRunningResumeCount = 2

    /// The number of `session/resume` requests that the agent got when only
    /// the first of two concurrent resumes went out.
    static let firstResumeOnlyCount = 1

    /// The number of resumes of one session that the concurrent-resume tests
    /// start at the same time.
    static let concurrentResumeCount = 2

    /// The number of agent messages in ``manyReplayedMessages``.
    static let manyReplayedMessageCount = 200

    /// Many agent messages, each one in one chunk, which give one transcript
    /// entry each.
    static let manyReplayedMessages = (0..<manyReplayedMessageCount).map { index in
        agentChunk(text: "message \(index)", message: "agent-\(index)")
    }

    /// The error of a resume that the agent does not advertise.
    static let resumeUnsupported = ConnectionModelError.unsupported(method: ClientRequestSpan.Method.resumeSession)

    /// The error that the agent refuses a resume with.
    static let resumeRefusal = RequestError.invalidParams

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

    /// An HTTP MCP server that the client sends.
    static let httpServer = MCPServer.http(MCPServerHTTP(name: "docs", url: "https://example.com/mcp"))

    /// A stdio MCP server that the client sends.
    static let stdioServer = MCPServer.stdio(
        MCPServerStdio(command: AbsolutePath(rawValue: "/usr/local/bin/files-mcp"), name: "files")
    )

    /// A second stdio MCP server, which only the resume request sends.
    static let searchServer = MCPServer.stdio(
        MCPServerStdio(command: AbsolutePath(rawValue: "/usr/local/bin/search-mcp"), name: "search")
    )

    /// An MCP server with a transport that this schema revision does not
    /// know. It never becomes an item.
    static let unknownServer = MCPServer.unknown(
        "sse",
        .object(["name": .string("events"), "url": .string("https://example.com/sse")])
    )

    /// The MCP servers of the new-session request of the MCP server tests:
    /// one server of each known transport, with an unknown server between
    /// them.
    static let newSessionServers = [httpServer, unknownServer, stdioServer]

    /// The new-session request that sends ``newSessionServers``.
    static let newSessionRequestWithServers = NewSessionRequest(
        cwd: workingDirectory,
        mcpServers: newSessionServers
    )

    /// The resume request of the test session that sends only
    /// ``searchServer``, with a replay from the start.
    static let resumeRequestWithServers = ResumeSessionRequest(
        cwd: workingDirectory,
        sessionId: testSession,
        mcpServers: [searchServer],
        replayFrom: replayFromStart
    )

    /// The servers of ``newSessionServers`` that an agent which advertises
    /// each MCP transport gets: the unknown server does not go out.
    static let advertisedNewSessionServers = [httpServer, stdioServer]

    /// The MCP capabilities of an agent that advertises each MCP transport.
    static let eachMCPTransport = MCPCapabilities(http: MCPHTTPCapabilities(), stdio: MCPStdioCapabilities())

    /// The capabilities of an agent that advertises the session baseline and
    /// each MCP transport.
    static let eachMCPTransportCapabilities = AgentCapabilities(session: SessionCapabilities(mcp: eachMCPTransport))

    /// The capabilities of an agent that advertises the session baseline and
    /// only the stdio MCP transport.
    static let stdioOnlyCapabilities = AgentCapabilities(
        session: SessionCapabilities(mcp: MCPCapabilities(stdio: MCPStdioCapabilities()))
    )

    /// The capabilities of an agent that advertises the session baseline and
    /// only the HTTP MCP transport.
    static let httpOnlyCapabilities = AgentCapabilities(
        session: SessionCapabilities(mcp: MCPCapabilities(http: MCPHTTPCapabilities()))
    )

    /// The items that ``newSessionServers`` give: the unknown server gives
    /// no item.
    static let newSessionServerRecords = [
        MCPServerRecord(name: "docs", transport: .http, origin: .client, server: httpServer, status: .notReported),
        MCPServerRecord(name: "files", transport: .stdio, origin: .client, server: stdioServer, status: .notReported),
    ]

    /// The item that ``resumeRequestWithServers`` gives.
    static let resumeServerRecords = [
        MCPServerRecord(name: "search", transport: .stdio, origin: .client, server: searchServer, status: .notReported)
    ]

    /// The `update` member of the example `_mcp_server_status` notification
    /// of the agent: the `files` stdio server of the client failed.
    static let exampleStatusUpdateJSON = """
        {"sessionUpdate":"_mcp_server_status","name":"files","transport":"stdio","origin":"client","status":"failed","reason":"\(exampleStatusReason)"}
        """

    /// The reason of ``exampleStatusUpdateJSON``.
    static let exampleStatusReason = "The command is not an absolute path."

    /// The items of ``newSessionServers`` after ``exampleStatusUpdateJSON``:
    /// only the `files` item changed.
    static let newSessionServerRecordsAfterStatus = [
        MCPServerRecord(name: "docs", transport: .http, origin: .client, server: httpServer, status: .notReported),
        MCPServerRecord(
            name: "files",
            transport: .stdio,
            origin: .client,
            server: stdioServer,
            status: .failed(reason: exampleStatusReason)
        ),
    ]

    /// Decodes ``exampleStatusUpdateJSON`` with the wire decoder.
    ///
    /// - Returns: The update, which this schema revision reads as
    ///   `SessionUpdate.unknown`.
    /// - Throws: `DecodingError` when the JSON does not decode.
    static func exampleStatusUpdate() throws -> SessionUpdate {
        try JSONDecoder().decode(SessionUpdate.self, from: Data(exampleStatusUpdateJSON.utf8))
    }

    /// Gives the fields of each MCP server item of a session model, in list
    /// order.
    ///
    /// - Parameter session: The session model.
    /// - Returns: One record for each item.
    @MainActor
    static func mcpServerRecords(of session: SessionModel) -> [MCPServerRecord] {
        session.mcpServers.map(MCPServerRecord.init(item:))
    }

    /// The working directory of the sessions of the additional-directory
    /// tests. It is not ``workingDirectory``, so a test can see that the
    /// model took it from the request.
    static let projectDirectory = AbsolutePath(rawValue: "/work/project")

    /// The additional directory of the new-session request of the
    /// additional-directory tests.
    static let sharedDirectory = AbsolutePath(rawValue: "/work/shared")

    /// The additional directory of the resume request of the
    /// additional-directory tests.
    static let documentsDirectory = AbsolutePath(rawValue: "/work/documents")

    /// The new-session request that sends ``projectDirectory`` and
    /// ``sharedDirectory``.
    static let newSessionRequestWithDirectories = NewSessionRequest(
        cwd: projectDirectory,
        additionalDirectories: [sharedDirectory]
    )

    /// The resume request of the test session that sends
    /// ``projectDirectory`` and ``documentsDirectory``, with a replay from
    /// the start.
    static let resumeRequestWithDirectories = ResumeSessionRequest(
        cwd: projectDirectory,
        sessionId: testSession,
        additionalDirectories: [documentsDirectory],
        replayFrom: replayFromStart
    )

    /// The resume request of the test session that sends
    /// ``projectDirectory`` and no additional directory, with a replay from
    /// the start.
    static let resumeRequestWithNoDirectories = ResumeSessionRequest(
        cwd: projectDirectory,
        sessionId: testSession,
        replayFrom: replayFromStart
    )

    /// The error of a new session with additional directories that the agent
    /// does not advertise.
    static let newSessionUnsupported = ConnectionModelError.unsupported(method: ClientRequestSpan.Method.newSession)

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
    ///   - afterNewSessionScript: The updates the agent sends after its
    ///     `session/new` answer.
    ///   - newSessionCommands: The command list of the `session/new` answer.
    ///   - closeSessionError: The error the agent refuses each close with, or
    ///     `nil` to accept each close.
    ///   - newSessionGate: The gate that must open before the agent answers
    ///     `session/new`, or `nil` to answer at once.
    ///   - resumeSessionScript: The updates the agent replays before its
    ///     `session/resume` answer.
    ///   - resumeSessionCommands: The command list of the `session/resume`
    ///     answer.
    ///   - resumeSessionError: The error the agent refuses each resume with,
    ///     or `nil` to accept each resume.
    ///   - resumeSessionGate: The gate that must open, after the replay,
    ///     before the agent answers `session/resume`, or `nil` to answer at
    ///     once.
    ///   - logger: The diagnostic sink of the model.
    /// - Returns: The connected model, after `initialize`.
    /// - Throws: Whatever `initialize` threw.
    @MainActor
    static func connect(
        capabilities: AgentCapabilities = InitializeFixtures.baselineCapabilities,
        logger: ACPLogger = .disabled,
        bufferLimits: SessionUpdateBufferLimits = .default,
        newSessionScript: [SessionUpdate] = [],
        afterNewSessionScript: [SessionUpdate] = [],
        newSessionCommands: [AvailableCommand]? = nil,
        closeSessionError: RequestError? = nil,
        newSessionGate: UpdateGate? = nil,
        resumeSessionScript: [SessionUpdate] = [],
        resumeSessionCommands: [AvailableCommand]? = nil,
        resumeSessionError: RequestError? = nil,
        resumeSessionGate: UpdateGate? = nil
    ) async throws -> ConnectedModel {
        let connected = await ConnectedModel(
            model: ConnectionModel(coalescingCadence: .zero, logger: logger),
            bufferLimits: bufferLimits
        ) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: [],
                closeSessionError: closeSessionError,
                newSessionScript: newSessionScript,
                afterNewSessionScript: afterNewSessionScript,
                newSessionCommands: newSessionCommands,
                resumeSessionScript: resumeSessionScript,
                resumeSessionCommands: resumeSessionCommands,
                resumeSessionError: resumeSessionError,
                resumeSessionGate: resumeSessionGate,
                capabilities: capabilities,
                newSessionGate: newSessionGate
            )
        }
        try await connected.initialize()
        return connected
    }

    /// Reads the outgoing-request events until the first request with a
    /// wire method finished.
    ///
    /// The connection sends `finished` when it takes the answer of the agent,
    /// before the caller of the request continues.
    ///
    /// - Parameters:
    ///   - method: The wire method of the request.
    ///   - events: The outgoing-request events of the connection, from a
    ///     subscription made before the request started.
    /// - Returns: `true` when the request finished, or `false` when the
    ///   stream ended first.
    static func requestFinished(_ method: String, in events: AsyncStream<OutgoingRequestEvent>) async -> Bool {
        var requestId: RequestId?
        for await event in events {
            switch event {
            case .started(let id, method):
                requestId = id
            case .finished(let id) where id == requestId:
                return true
            case .started, .finished:
                continue
            }
        }
        return false
    }

    /// Counts the `session/resume` requests that the agent got.
    ///
    /// - Parameter connected: The connected model and its stub agent.
    /// - Returns: The number of `session/resume` requests in the record of
    ///   the agent.
    @MainActor
    static func resumeRequestCount(of connected: ConnectedModel) -> Int {
        connected.receivedMethods.count { $0 == ClientRequestSpan.Method.resumeSession }
    }

    /// Starts a resume of the test session that runs on the main actor up to
    /// its first suspension before this call returns.
    ///
    /// Thus the resume has entered `resumeSession(_:)` when the test goes on,
    /// with no wait.
    ///
    /// - Parameter model: The connection model that resumes.
    /// - Returns: The task of the resume.
    @MainActor
    static func startResumeNow(on model: ConnectionModel) -> Task<SessionModel, any Error> {
        Task.immediate { @MainActor in
            try await model.resumeSession(resumeRequest)
        }
    }

    /// Gives the text of each agent message of a session model, in
    /// transcript order.
    ///
    /// - Parameter session: The session model.
    /// - Returns: The joined text of each entry, or `nil` for an entry that
    ///   is not an agent message.
    @MainActor
    static func messageTexts(of session: SessionModel) -> [String?] {
        session.transcript.map { $0.agentMessage?.content.joinedText }
    }

    /// Reads a session stream until it gave a number of updates. The request
    /// markers of the stream do not count.
    ///
    /// - Parameters:
    ///   - count: The number of updates to read.
    ///   - events: The iterator of the session stream.
    @MainActor
    static func skipUpdates(_ count: Int, of events: inout AsyncStream<SessionStreamEvent>.Iterator) async {
        var updates = 0
        while updates < count, let event = await events.next(isolation: MainActor.shared) {
            if case .update = event {
                updates += 1
            }
        }
    }

    /// Makes a subscription that holds each event of a session stream until a
    /// gate opens, and then passes the events on in order.
    ///
    /// A session model attached to this subscription is a model whose stream
    /// task is behind the connection: the connection already yielded an event
    /// that the model did not read yet.
    ///
    /// - Parameters:
    ///   - events: The session stream of the connection.
    ///   - gate: The gate that releases the events.
    /// - Returns: The subscription to attach to the model.
    static func heldSubscription(
        of events: AsyncStream<SessionStreamEvent>,
        until gate: UpdateGate
    ) -> SessionUpdateSubscription {
        let (subscription, continuation) = SessionModelFixtures.handMadeSubscription()
        let relay = Task {
            await gate.wait()
            for await event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in relay.cancel() }
        return subscription
    }

    /// Runs one operation of the connection model under a task executor that
    /// the test holds. The test then decides when the part of the call that
    /// follows the answer of the agent runs.
    ///
    /// - Parameters:
    ///   - executor: The executor that the test holds.
    ///   - operation: The operation to run.
    /// - Returns: The task of the operation.
    @MainActor
    static func runHeld<Output: Sendable>(
        on executor: HoldableTaskExecutor,
        _ operation: @escaping @MainActor () async throws -> Output
    ) -> Task<Output, any Error> {
        Task {
            try await withTaskExecutorPreference(executor) {
                try await operation()
            }
        }
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

    @Test func aConnectionThatClosesAfterTheNewSessionAnswerRegistersNoSession() async throws {
        let answerGate = UpdateGate()
        let connected = try await SessionFactoryFixtures.connect(newSessionGate: answerGate)
        let requestEvents = try #require(connected.model.connection).subscribeToOutgoingRequests()
        let executor = HoldableTaskExecutor()
        let creating = SessionFactoryFixtures.runHeld(on: executor) { [model = connected.model] in
            try await model.newSession(SessionFactoryFixtures.newSessionRequest)
        }
        try await waitUntil { connected.receivedMethods.contains(ClientRequestSpan.Method.newSession) }

        // The executor holds the part of the call that follows the answer, so
        // the close of the connection always comes before `newSession` reads
        // the answer.
        try await executor.whileHeld {
            answerGate.open()
            #expect(await SessionFactoryFixtures.requestFinished(ClientRequestSpan.Method.newSession, in: requestEvents))
            connected.agentEnd.close()
            try await waitUntil { connected.model.state == .disconnected }
        }

        await #expect(throws: ConnectionError.closed) {
            try await creating.value
        }
        #expect(connected.model.openSessions.isEmpty)
    }

    // MARK: - resumeSession

    @Test func resumeOfANewSessionRegistersAModelWithTheReplay() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionScript: SessionFactoryFixtures.chunkedReplay
        )

        let session = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequest)

        #expect(connected.model.session(for: testSession) === session)
        #expect(SessionFactoryFixtures.messageTexts(of: session) == [SessionFactoryFixtures.replayedText])
        #expect(!session.isReplaying)
        #expect(session.history == .retained(replayFrom: SessionFactoryFixtures.replayFromStart))
    }

    @Test func aReplayGoesIntoTheModelWhileTheModelReplays() async throws {
        let answerGate = UpdateGate()
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionScript: SessionFactoryFixtures.chunkedReplay,
            resumeSessionGate: answerGate
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)
        let resuming = Task { [model = connected.model] in
            try await model.resumeSession(SessionFactoryFixtures.resumeRequest)
        }

        try await waitUntil {
            SessionFactoryFixtures.messageTexts(of: session) == [SessionFactoryFixtures.replayedText]
        }
        #expect(session.isReplaying)
        answerGate.open()

        #expect(try await resuming.value === session)
        #expect(!session.isReplaying)
    }

    @Test func aSecondResumeOfAnOpenSessionGivesTheSameModelWithNoDoubledText() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionScript: SessionFactoryFixtures.chunkedReplay
        )
        let first = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequest)

        let second = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequest)

        #expect(second === first)
        #expect(SessionFactoryFixtures.messageTexts(of: second) == [SessionFactoryFixtures.replayedText])
    }

    @Test func eachReplayedUpdateIsInTheModelWhenTheResumeReturns() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionScript: SessionFactoryFixtures.manyReplayedMessages
        )

        let session = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequest)

        #expect(session.transcript.count == SessionFactoryFixtures.manyReplayedMessageCount)
        #expect(!session.isReplaying)
    }

    @Test func aReplayFromTheStartAfterAnOverflowClearsTheMissedUpdatesMark() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            bufferLimits: SessionFactoryFixtures.oneUpdateBuffer,
            newSessionScript: SessionFactoryFixtures.twoMessages,
            resumeSessionScript: SessionFactoryFixtures.chunkedReplay
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)
        try #require(session.hasMissedUpdates)

        let resumed = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequest)

        #expect(resumed === session)
        #expect(!session.hasMissedUpdates)
        #expect(SessionFactoryFixtures.messageTexts(of: session) == [SessionFactoryFixtures.replayedText])
    }

    @Test func aResumeAnswerWithACommandListSeedsTheCommands() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionCommands: SessionFactoryFixtures.commands
        )

        let session = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequest)

        #expect(session.availableCommands == SessionFactoryFixtures.commands)
    }

    @Test func aRefusedResumeOfANewSessionThrowsItsErrorAndRegistersNoSession() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionError: SessionFactoryFixtures.resumeRefusal
        )

        await #expect(throws: SessionFactoryFixtures.resumeRefusal) {
            try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequest)
        }

        #expect(connected.model.openSessions.isEmpty)
    }

    @Test func aRefusedResumeOfAnOpenSessionEndsTheReplayAndKeepsTheModelOpen() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionError: SessionFactoryFixtures.resumeRefusal
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        await #expect(throws: SessionFactoryFixtures.resumeRefusal) {
            try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequest)
        }

        #expect(!session.isReplaying)
        #expect(session.history == .live)
        #expect(!session.isClosed)
        #expect(connected.model.session(for: testSession) === session)
    }

    @Test func resumeWithNoCapabilityThrowsUnsupportedAndSendsNothing() async throws {
        let connected = try await SessionFactoryFixtures.connect(capabilities: AgentCapabilities())

        await #expect(throws: SessionFactoryFixtures.resumeUnsupported) {
            try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequest)
        }
        // A second initialize makes a round trip after the refused resume, so
        // a resume that went out would be in the record before its answer.
        try await connected.initialize()

        #expect(!connected.receivedMethods.contains(ClientRequestSpan.Method.resumeSession))
        #expect(connected.model.openSessions.isEmpty)
    }

    @Test func aConnectionThatClosesAfterTheResumeAnswerRegistersNoSession() async throws {
        let answerGate = UpdateGate()
        let connected = try await SessionFactoryFixtures.connect(resumeSessionGate: answerGate)
        let requestEvents = try #require(connected.model.connection).subscribeToOutgoingRequests()
        let executor = HoldableTaskExecutor()
        let resuming = SessionFactoryFixtures.runHeld(on: executor) { [model = connected.model] in
            try await model.resumeSession(SessionFactoryFixtures.resumeRequest)
        }
        try await waitUntil { connected.receivedMethods.contains(ClientRequestSpan.Method.resumeSession) }

        // The executor holds the part of the call that follows the answer, so
        // the close of the connection always comes before `resumeSession`
        // reads the answer.
        try await executor.whileHeld {
            answerGate.open()
            #expect(await SessionFactoryFixtures.requestFinished(ClientRequestSpan.Method.resumeSession, in: requestEvents))
            connected.agentEnd.close()
            try await waitUntil { connected.model.state == .disconnected }
        }

        await #expect(throws: ConnectionError.closed) {
            try await resuming.value
        }
        #expect(connected.model.openSessions.isEmpty)
    }

    @Test func aResumeAfterACancelledStartedResumeEndsItsReplayOnlyAtItsOwnMarker() async throws {
        let answerGate = UpdateGate()
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionScript: SessionFactoryFixtures.chunkedReplay,
            resumeSessionGate: answerGate
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)
        let connection = try #require(connected.model.connection)
        // The model reads the session stream only after `streamGate` opens, so
        // the marker of the cancelled resume is still unread when the second
        // resume starts its replay. `wire` reads the same stream at once.
        let streamGate = UpdateGate()
        session.attach(SessionFactoryFixtures.heldSubscription(of: connection.subscribe(to: testSession).updates, until: streamGate))
        var wire = connection.subscribe(to: testSession).updates.makeAsyncIterator()
        var tap = session.updateTap().makeAsyncIterator()
        let replayLength = SessionFactoryFixtures.chunkedReplay.count

        let cancelled = Task { [model = connected.model] in
            try await model.resumeSession(SessionFactoryFixtures.resumeRequest)
        }
        await SessionFactoryFixtures.skipUpdates(replayLength, of: &wire)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        let resuming = Task { [model = connected.model] in
            try await model.resumeSession(SessionFactoryFixtures.resumeRequest)
        }
        await SessionFactoryFixtures.skipUpdates(replayLength, of: &wire)

        // The stream holds the replay of the cancelled resume, its marker, and
        // the replay of the running resume. When the tap gave the chunks of
        // both replays, the model read that marker.
        streamGate.open()
        for _ in 0..<(SessionFactoryFixtures.cancelledAndRunningResumeCount * replayLength) {
            _ = await tap.next()
        }
        #expect(session.isReplaying)

        answerGate.open()
        #expect(try await resuming.value === session)
        #expect(!session.isReplaying)
        #expect(session.history == .retained(replayFrom: SessionFactoryFixtures.replayFromStart))
    }

    @Test func twoConcurrentResumesOfANewSessionGiveOneModelWithOneReplayEach() async throws {
        let answerGate = UpdateGate()
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionScript: SessionFactoryFixtures.chunkedReplay,
            resumeSessionGate: answerGate
        )
        let first = Task { [model = connected.model] in
            try await model.resumeSession(SessionFactoryFixtures.resumeRequest)
        }
        try await waitUntil {
            SessionFactoryFixtures.resumeRequestCount(of: connected) == SessionFactoryFixtures.firstResumeOnlyCount
        }

        // The gate holds the answer of the first resume, so the second resume
        // enters `resumeSession(_:)` while the first one runs.
        let second = SessionFactoryFixtures.startResumeNow(on: connected.model)
        answerGate.open()

        let firstModel = try await first.value
        let secondModel = try await second.value
        #expect(secondModel === firstModel)
        #expect(connected.model.session(for: testSession) === firstModel)
        #expect(SessionFactoryFixtures.messageTexts(of: firstModel) == [SessionFactoryFixtures.replayedText])
        #expect(!firstModel.isReplaying)
        #expect(firstModel.history == .retained(replayFrom: SessionFactoryFixtures.replayFromStart))
        #expect(SessionFactoryFixtures.resumeRequestCount(of: connected) == SessionFactoryFixtures.concurrentResumeCount)
    }

    @Test func aCancelledFirstResumeDoesNotEndTheReplayOfTheSecondResume() async throws {
        let answerGate = UpdateGate()
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionScript: SessionFactoryFixtures.chunkedReplay,
            resumeSessionGate: answerGate
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)
        let cancelled = Task { [model = connected.model] in
            try await model.resumeSession(SessionFactoryFixtures.resumeRequest)
        }
        try await waitUntil {
            SessionFactoryFixtures.resumeRequestCount(of: connected) == SessionFactoryFixtures.firstResumeOnlyCount
        }
        let resuming = SessionFactoryFixtures.startResumeNow(on: connected.model)

        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        try await waitUntil {
            SessionFactoryFixtures.resumeRequestCount(of: connected) == SessionFactoryFixtures.concurrentResumeCount
        }

        // The gate still holds the answer of the second resume, so its replay
        // runs.
        #expect(session.isReplaying)
        answerGate.open()
        #expect(try await resuming.value === session)
        #expect(!session.isReplaying)
        #expect(session.history == .retained(replayFrom: SessionFactoryFixtures.replayFromStart))
    }

    @Test func aWaitingResumeThatItsTaskCancelsThrowsAtOnceAndSendsNothing() async throws {
        let answerGate = UpdateGate()
        let connected = try await SessionFactoryFixtures.connect(
            resumeSessionScript: SessionFactoryFixtures.chunkedReplay,
            resumeSessionGate: answerGate
        )
        let first = Task { [model = connected.model] in
            try await model.resumeSession(SessionFactoryFixtures.resumeRequest)
        }
        try await waitUntil {
            SessionFactoryFixtures.resumeRequestCount(of: connected) == SessionFactoryFixtures.firstResumeOnlyCount
        }
        let waiting = SessionFactoryFixtures.startResumeNow(on: connected.model)

        // The gate holds the answer of the first resume, so the cancelled
        // resume ends while the first one still runs.
        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        answerGate.open()
        let session = try await first.value
        // A second initialize makes a round trip after the first resume, so a
        // resume that went out would be in the record before its answer.
        try await connected.initialize()

        #expect(SessionFactoryFixtures.resumeRequestCount(of: connected) == SessionFactoryFixtures.firstResumeOnlyCount)
        #expect(!session.isReplaying)
        #expect(session.history == .retained(replayFrom: SessionFactoryFixtures.replayFromStart))
    }

    // MARK: - MCP servers

    @Test func newSessionHoldsItsMCPServersAsNotReported() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: SessionFactoryFixtures.eachMCPTransportCapabilities
        )

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithServers)

        #expect(SessionFactoryFixtures.mcpServerRecords(of: session) == SessionFactoryFixtures.newSessionServerRecords)
    }

    @Test func resumeReplacesTheMCPServersOfAnOpenSession() async throws {
        let answerGate = UpdateGate()
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: SessionFactoryFixtures.eachMCPTransportCapabilities,
            resumeSessionGate: answerGate
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithServers)
        let resuming = Task { [model = connected.model] in
            try await model.resumeSession(SessionFactoryFixtures.resumeRequestWithServers)
        }
        try await waitUntil { connected.receivedMethods.contains(ClientRequestSpan.Method.resumeSession) }

        // The gate holds the answer of the agent, so the list of the resume
        // request is in the model before the response.
        #expect(SessionFactoryFixtures.mcpServerRecords(of: session) == SessionFactoryFixtures.resumeServerRecords)
        answerGate.open()

        #expect(try await resuming.value === session)
        #expect(SessionFactoryFixtures.mcpServerRecords(of: session) == SessionFactoryFixtures.resumeServerRecords)
    }

    @Test func aFailedResumeKeepsTheMCPServers() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: SessionFactoryFixtures.eachMCPTransportCapabilities,
            resumeSessionError: SessionFactoryFixtures.resumeRefusal
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithServers)
        let itemsBeforeResume = session.mcpServers

        await #expect(throws: SessionFactoryFixtures.resumeRefusal) {
            try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequestWithServers)
        }

        #expect(session.mcpServers.map(ObjectIdentifier.init) == itemsBeforeResume.map(ObjectIdentifier.init))
        #expect(SessionFactoryFixtures.mcpServerRecords(of: session) == SessionFactoryFixtures.newSessionServerRecords)
    }

    @Test func newSessionAppliesAStatusUpdateThatFollowsTheResponse() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: SessionFactoryFixtures.eachMCPTransportCapabilities,
            afterNewSessionScript: [try SessionFactoryFixtures.exampleStatusUpdate()]
        )

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithServers)

        try await waitUntil { session.mcpServers.contains { $0.status != .notReported } }
        #expect(
            SessionFactoryFixtures.mcpServerRecords(of: session) == SessionFactoryFixtures.newSessionServerRecordsAfterStatus
        )
        #expect(session.transcript.isEmpty)
    }

    @Test func aRequestWithNoMCPServersGivesAnEmptyList() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: SessionFactoryFixtures.eachMCPTransportCapabilities
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)
        #expect(session.mcpServers.isEmpty)
        _ = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequestWithServers)
        try #require(!session.mcpServers.isEmpty)

        _ = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequest)

        #expect(session.mcpServers.isEmpty)
    }

    // MARK: - MCP transports that the agent advertises

    @Test func newSessionSendsEachServerWhoseTransportTheAgentAdvertises() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: SessionFactoryFixtures.eachMCPTransportCapabilities
        )

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithServers)

        #expect(connected.newSessionMCPServers == [SessionFactoryFixtures.advertisedNewSessionServers])
        #expect(SessionFactoryFixtures.mcpServerRecords(of: session) == SessionFactoryFixtures.newSessionServerRecords)
    }

    @Test func newSessionRemovesAnHTTPServerThatTheAgentDoesNotAdvertise() async throws {
        let messages = ThreadSafeBuffer<String>()
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: SessionFactoryFixtures.stdioOnlyCapabilities,
            logger: ACPLogger { messages.append($0) }
        )

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithServers)

        #expect(connected.newSessionMCPServers == [[SessionFactoryFixtures.stdioServer]])
        #expect(session.mcpServers.map(\.name) == ["files"])
        // The agent does not get the HTTP server and the unknown server, so
        // the log has one warning for each of them.
        #expect(messages.elements.count == 2)
        #expect(messages.elements.contains { $0.contains("\"docs\"") && $0.contains("http") })
        #expect(messages.elements.contains { $0.contains("\"events\"") && $0.contains("sse") })
    }

    @Test func newSessionWithNoMCPCapabilitySendsNoServer() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: InitializeFixtures.baselineCapabilities
        )

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithServers)

        #expect(connected.newSessionMCPServers == [[]])
        #expect(session.mcpServers.isEmpty)
        #expect(connected.model.session(for: testSession) === session)
    }

    @Test func resumeSessionRemovesAServerThatTheAgentDoesNotAdvertise() async throws {
        let messages = ThreadSafeBuffer<String>()
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: SessionFactoryFixtures.httpOnlyCapabilities,
            logger: ACPLogger { messages.append($0) }
        )

        let session = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequestWithServers)

        #expect(connected.resumeSessionMCPServers == [[]])
        #expect(session.mcpServers.isEmpty)
        #expect(messages.elements.count == 1)
        #expect(messages.elements.contains { $0.contains("\"search\"") && $0.contains("stdio") })
    }

    @Test func removingUnadvertisedMCPServersChangesOnlyTheServersOfEachRequestKind() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: SessionFactoryFixtures.stdioOnlyCapabilities
        )
        var expectedNewSession = SessionFactoryFixtures.newSessionRequestWithServers
        expectedNewSession.mcpServers = [SessionFactoryFixtures.stdioServer]

        let newSession = connected.model.removingUnadvertisedMCPServers(
            from: SessionFactoryFixtures.newSessionRequestWithServers
        )
        let resume = connected.model.removingUnadvertisedMCPServers(
            from: SessionFactoryFixtures.resumeRequestWithServers
        )

        // One helper filters the two kinds of request. Each other field of
        // the request stays as the caller made it.
        #expect(newSession == expectedNewSession)
        #expect(resume == SessionFactoryFixtures.resumeRequestWithServers)
    }

    // MARK: - The working directory and the additional directories

    @Test func newSessionHoldsTheCwdAndTheAdditionalDirectories() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: InitializeFixtures.additionalDirectoriesCapabilities
        )

        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithDirectories)

        #expect(session.cwd == SessionFactoryFixtures.projectDirectory)
        #expect(session.cwd == connected.lastWorkingDirectory)
        #expect(session.additionalDirectories == [SessionFactoryFixtures.sharedDirectory])
    }

    @Test func resumeSessionHoldsTheValuesOfANewModel() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: InitializeFixtures.additionalDirectoriesCapabilities
        )

        let session = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequestWithDirectories)

        #expect(session.cwd == SessionFactoryFixtures.projectDirectory)
        #expect(session.additionalDirectories == [SessionFactoryFixtures.documentsDirectory])
    }

    @Test func resumeOfAnOpenSessionReplacesTheValues() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: InitializeFixtures.additionalDirectoriesCapabilities
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithDirectories)

        let resumed = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequestWithDirectories)

        #expect(resumed === session)
        #expect(session.cwd == SessionFactoryFixtures.projectDirectory)
        #expect(session.additionalDirectories == [SessionFactoryFixtures.documentsDirectory])

        // A resume with no list activates no additional root, so the model
        // then holds an empty list.
        _ = try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequestWithNoDirectories)

        #expect(session.additionalDirectories.isEmpty)
    }

    @Test func aFailedResumeKeepsTheValues() async throws {
        let connected = try await SessionFactoryFixtures.connect(
            capabilities: InitializeFixtures.additionalDirectoriesCapabilities,
            resumeSessionError: SessionFactoryFixtures.resumeRefusal
        )
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithDirectories)

        await #expect(throws: SessionFactoryFixtures.resumeRefusal) {
            try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequestWithDirectories)
        }

        #expect(session.cwd == SessionFactoryFixtures.projectDirectory)
        #expect(session.additionalDirectories == [SessionFactoryFixtures.sharedDirectory])
    }

    @Test func additionalDirectoriesWithNoCapabilityThrowsAndSendsNothing() async throws {
        let connected = try await SessionFactoryFixtures.connect(capabilities: InitializeFixtures.baselineCapabilities)

        await #expect(throws: SessionFactoryFixtures.newSessionUnsupported) {
            try await connected.model.newSession(SessionFactoryFixtures.newSessionRequestWithDirectories)
        }
        await #expect(throws: SessionFactoryFixtures.resumeUnsupported) {
            try await connected.model.resumeSession(SessionFactoryFixtures.resumeRequestWithDirectories)
        }
        // A second initialize makes a round trip after the refused requests,
        // so a request that went out would be in the record before its answer.
        try await connected.initialize()

        #expect(!connected.receivedMethods.contains(ClientRequestSpan.Method.newSession))
        #expect(!connected.receivedMethods.contains(ClientRequestSpan.Method.resumeSession))
        #expect(connected.model.openSessions.isEmpty)
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

        #expect(connected.receivedMethods.last == ClientRequestSpan.Method.setConfigOption)
    }

    // MARK: - Routing of the updates

    @Test func updatesForTwoOpenSessionsLandInTheirOwnModels() async throws {
        let connected = try await SessionFactoryFixtures.connect()
        let first = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)
        let second = try await connected.model.resumeSession(
            ResumeSessionRequest(cwd: SessionFactoryFixtures.workingDirectory, sessionId: otherTestSession)
        )

        try await connected.agentConnection.sessionUpdate(
            UpdateSessionNotification(sessionId: testSession, update: agentChunk(text: "first", message: "agent-1"))
        )
        try await connected.agentConnection.sessionUpdate(
            UpdateSessionNotification(sessionId: otherTestSession, update: agentChunk(text: "second", message: "agent-2"))
        )

        try await waitUntil { !first.transcript.isEmpty && !second.transcript.isEmpty }
        #expect(SessionFactoryFixtures.messageTexts(of: first) == ["first"])
        #expect(SessionFactoryFixtures.messageTexts(of: second) == ["second"])
    }

    @Test func aWrapThatForwardsEachCallKeepsTheTranscriptCurrent() async throws {
        let factory = ForwardingClientFactory()
        let connected = await ConnectedModel(
            model: ConnectionModel(coalescingCadence: .zero),
            client: { [factory] router in factory.wrap(router) }
        ) { connection in
            ScriptedStubAgent(connection: connection, session: testSession, script: SessionFactoryFixtures.twoMessages)
        }
        try await connected.initialize()
        let session = try await connected.model.newSession(SessionFactoryFixtures.newSessionRequest)

        _ = try await session.prompt([textBlock("Hello")])

        try await waitUntil { SessionFactoryFixtures.messageTexts(of: session).compactMap(\.self) == ["first", "second"] }
        #expect(factory.built.count == 1)
        #expect(try #require(factory.built.first).forwardedUpdateCount == SessionFactoryFixtures.twoMessages.count)
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

/// A `Client` that stands in front of the router of a connection model,
/// forwards each call to it, and counts the session updates it forwards.
///
/// This is the shape that ``ConnectionModel/connect(over:logger:bufferLimits:client:)``
/// documents for a host that puts its own `Client` in front of the router.
@MainActor
private final class ForwardingClient: Client {
    /// The router that this client stands in front of.
    private let router: any Client

    /// The number of session updates that this client forwarded.
    private(set) var forwardedUpdateCount = 0

    /// Makes the client.
    ///
    /// - Parameter router: The router that this client stands in front of.
    init(router: any Client) {
        self.router = router
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        forwardedUpdateCount += 1
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

/// Builds the ``ForwardingClient`` of each connection and keeps it, so a test
/// can read what each one forwarded.
@MainActor
private final class ForwardingClientFactory {
    /// Each client that ``wrap(_:)`` built, in build order.
    private(set) var built: [ForwardingClient] = []

    /// Builds a forwarding client in front of a router.
    ///
    /// - Parameter router: The router of the connection model.
    /// - Returns: The client that the connection serves.
    func wrap(_ router: any Client) -> any Client {
        let client = ForwardingClient(router: router)
        built.append(client)
        return client
    }
}

/// The fields of one ``MCPServerItem``, as a value that a test can compare.
private struct MCPServerRecord: Equatable {
    /// The name of the server.
    let name: String

    /// The transport of the server.
    let transport: MCPServerTransport

    /// The source of the server.
    let origin: MCPServerOrigin

    /// The configuration that the client sent, or `nil`.
    let server: MCPServer?

    /// The last status of the server.
    let status: MCPServerStatus
}

extension MCPServerRecord {
    /// Copies the fields of an item.
    ///
    /// - Parameter item: The item to copy.
    @MainActor
    init(item: MCPServerItem) {
        self.init(
            name: item.name,
            transport: item.transport,
            origin: item.origin,
            server: item.server,
            status: item.status
        )
    }
}
