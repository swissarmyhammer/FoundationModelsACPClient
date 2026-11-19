import ACPMarkdown
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of `ConnectionModel.forkSession(_:cut:)`.
//
// `ConnectedModel` gives the real ACP wire, with a `ScriptedStubAgent` on the
// agent end. The stub answers `session/new` with the source session, and
// `session/fork` with the fork. The script session of the stub is the fork,
// so the stub sends its `resumeSessionScript` as the replay of the fork.

/// The fixtures of the fork tests.
private enum ForkFixtures {
    /// The session that the agent makes for the fork.
    static let forkedSession = SessionId(rawValue: "fork-1")

    /// The working directory of the source session.
    static let projectDirectory = AbsolutePath(rawValue: "/work/project")

    /// The additional directory of the source session.
    static let sharedDirectory = AbsolutePath(rawValue: "/work/shared")

    /// The new-session request that opens the source session, with no
    /// additional directory.
    static let sourceRequest = NewSessionRequest(cwd: projectDirectory)

    /// The new-session request that opens the source session with
    /// ``sharedDirectory``.
    static let sourceRequestWithDirectories = NewSessionRequest(
        cwd: projectDirectory,
        additionalDirectories: [sharedDirectory]
    )

    /// An HTTP MCP server of the source session.
    static let httpServer = MCPServer.http(MCPServerHTTP(name: "docs", url: "https://example.com/mcp"))

    /// A stdio MCP server of the source session.
    static let stdioServer = MCPServer.stdio(
        MCPServerStdio(command: AbsolutePath(rawValue: "/usr/local/bin/files-mcp"), name: "files")
    )

    /// The new-session request that opens the source session with both MCP
    /// servers.
    static let sourceRequestWithServers = NewSessionRequest(
        cwd: projectDirectory,
        mcpServers: [httpServer, stdioServer]
    )

    /// The cut of the cut tests: after one agent message.
    static let cut = SAH.ForkCut(messageId: MessageId(rawValue: "agent-1"), side: .after)

    /// The replay of the fork: one agent message, in two chunks.
    static let replay = [
        agentChunk(text: "Hel", message: "agent-1"),
        agentChunk(text: "lo", message: "agent-1"),
    ]

    /// The text of the message of ``replay``.
    static let replayedText = "Hello"

    /// The error of a fork that the agent does not advertise.
    static let forkUnsupported = ConnectionModelError.unsupported(method: ClientRequestSpan.Method.forkSession)

    /// The error that the agent refuses the resume of the fork with.
    static let resumeRefusal = RequestError.invalidParams

    /// The capabilities of an agent that forks with no cut, and takes
    /// additional directories.
    static let forkWithDirectories = AgentCapabilities(
        session: SessionCapabilities(
            additionalDirectories: SessionAdditionalDirectoriesCapabilities(),
            fork: SessionForkCapabilities()
        )
    )

    /// The capabilities of an agent that forks with no cut, and advertises
    /// only the stdio MCP transport.
    static let forkWithStdioOnly = AgentCapabilities(
        session: SessionCapabilities(
            fork: SessionForkCapabilities(),
            mcp: MCPCapabilities(stdio: MCPStdioCapabilities())
        )
    )

    /// Connects a model to a stub agent, and sends `initialize`.
    ///
    /// - Parameters:
    ///   - capabilities: The capabilities the agent answers `initialize`
    ///     with.
    ///   - resumeSessionScript: The updates the agent replays before its
    ///     `session/resume` answer.
    ///   - resumeSessionError: The error the agent refuses each resume with,
    ///     or `nil` to accept each resume.
    ///   - forkSessionGate: The gate that must open before the agent answers
    ///     `session/fork`, or `nil` to answer at once.
    /// - Returns: The connected model, after `initialize`.
    /// - Throws: Whatever `initialize` threw.
    @MainActor
    static func connect(
        capabilities: AgentCapabilities = InitializeFixtures.forkCapabilities,
        resumeSessionScript: [SessionUpdate] = [],
        resumeSessionError: RequestError? = nil,
        forkSessionGate: UpdateGate? = nil
    ) async throws -> ConnectedModel {
        let connected = await ConnectedModel(model: ConnectionModel(coalescingCadence: .zero)) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: forkedSession,
                script: [],
                newSessionIds: [testSession],
                resumeSessionScript: resumeSessionScript,
                resumeSessionError: resumeSessionError,
                capabilities: capabilities,
                forkSessionGate: forkSessionGate
            )
        }
        try await connected.initialize()
        return connected
    }

    /// Tells whether the agent got a `session/fork` request.
    ///
    /// A second `initialize` makes a round trip first, so a fork request that
    /// went out before the call is in the record of the agent.
    ///
    /// - Parameter connected: The connected model and its stub agent.
    /// - Returns: `true` when the agent got a fork request.
    /// - Throws: Whatever `initialize` threw.
    @MainActor
    static func agentGotAFork(on connected: ConnectedModel) async throws -> Bool {
        try await connected.initialize()
        return connected.receivedMethods.contains(ClientRequestSpan.Method.forkSession)
    }
}

/// The fields of a `session/fork` request that the tests compare.
private struct ForkRecord: Equatable {
    /// The source session.
    let sessionId: SessionId

    /// The working directory.
    let cwd: AbsolutePath

    /// The additional directories, or `nil` when the request sends no list.
    let additionalDirectories: [AbsolutePath]?

    /// The cut in `_meta.sah.forkCut`, or `nil` when the request has no cut.
    let cut: SAH.ForkCut?
}

extension ForkRecord {
    /// Reads the compared fields of a request.
    ///
    /// - Parameter request: The request that the agent got.
    init(_ request: ForkSessionRequest) {
        self.init(
            sessionId: request.sessionId,
            cwd: request.cwd,
            additionalDirectories: request.additionalDirectories,
            cut: SAH.ForkCut.extract(from: request.meta)
        )
    }
}

/// The fork tests of the connection model, in one suite so that
/// `swift test --filter ConnectionModelForkTests` selects them.
@MainActor
@Suite
struct ConnectionModelForkTests {
    @Test func forkSendsTheSourceWorkspaceWithNoCut() async throws {
        let connected = try await ForkFixtures.connect(capabilities: ForkFixtures.forkWithDirectories)
        defer { await connected.model.disconnect() }
        _ = try await connected.model.newSession(ForkFixtures.sourceRequestWithDirectories)

        _ = try await connected.model.forkSession(testSession)

        let expected = ForkRecord(
            sessionId: testSession,
            cwd: ForkFixtures.projectDirectory,
            additionalDirectories: [ForkFixtures.sharedDirectory],
            cut: nil
        )
        #expect(connected.forkRequests.map(ForkRecord.init) == [expected])
    }

    @Test func forkRegistersAnOpenModelForTheNewSession() async throws {
        let connected = try await ForkFixtures.connect()
        defer { await connected.model.disconnect() }
        _ = try await connected.model.newSession(ForkFixtures.sourceRequest)

        let fork = try await connected.model.forkSession(testSession)

        #expect(connected.model.session(for: ForkFixtures.forkedSession) === fork)
    }

    @Test func forkWithACutSendsTheCutInTheMeta() async throws {
        let connected = try await ForkFixtures.connect(capabilities: InitializeFixtures.forkCutCapabilities())
        defer { await connected.model.disconnect() }
        _ = try await connected.model.newSession(ForkFixtures.sourceRequest)

        _ = try await connected.model.forkSession(testSession, cut: ForkFixtures.cut)

        #expect(connected.forkRequests.map { SAH.ForkCut.extract(from: $0.meta) } == [ForkFixtures.cut])
    }

    @Test func forkWithNoCapabilityThrowsUnsupportedAndSendsNothing() async throws {
        let connected = try await ForkFixtures.connect(capabilities: InitializeFixtures.baselineCapabilities)
        defer { await connected.model.disconnect() }
        _ = try await connected.model.newSession(ForkFixtures.sourceRequest)

        await #expect(throws: ForkFixtures.forkUnsupported) {
            try await connected.model.forkSession(testSession)
        }
        #expect(try await !ForkFixtures.agentGotAFork(on: connected))
    }

    @Test func aCutWithNoCutCapabilityThrowsUnsupportedAndSendsNothing() async throws {
        let connected = try await ForkFixtures.connect()
        defer { await connected.model.disconnect() }
        _ = try await connected.model.newSession(ForkFixtures.sourceRequest)

        await #expect(throws: ForkFixtures.forkUnsupported) {
            try await connected.model.forkSession(testSession, cut: ForkFixtures.cut)
        }
        #expect(try await !ForkFixtures.agentGotAFork(on: connected))
    }

    @Test func aForkOfTheSessionIdOfAReadOnlyModelThrowsNotOpenAndSendsNothing() async throws {
        let connected = try await ForkFixtures.connect()
        defer { await connected.model.disconnect() }
        let shared = SessionModel(snapshot: SessionSnapshot.build(updates: ForkFixtures.replay), sessionId: testSession)

        await #expect(throws: ConnectionModelError.sessionNotOpen(sessionId: testSession)) {
            try await connected.model.forkSession(shared.sessionId)
        }
        #expect(try await !ForkFixtures.agentGotAFork(on: connected))
    }

    @Test func forkOfASessionThatIsNotOpenThrowsAndSendsNothing() async throws {
        let connected = try await ForkFixtures.connect()
        defer { await connected.model.disconnect() }

        await #expect(throws: ConnectionModelError.sessionNotOpen(sessionId: testSession)) {
            try await connected.model.forkSession(testSession)
        }
        #expect(try await !ForkFixtures.agentGotAFork(on: connected))
    }

    @Test func forkSendsTheMCPServersOfTheSourceThatTheAgentAdvertises() async throws {
        let connected = try await ForkFixtures.connect(capabilities: ForkFixtures.forkWithStdioOnly)
        defer { await connected.model.disconnect() }
        _ = try await connected.model.newSession(ForkFixtures.sourceRequestWithServers)

        _ = try await connected.model.forkSession(testSession)

        #expect(connected.forkRequests.map(\.mcpServers) == [[ForkFixtures.stdioServer]])
    }

    @Test func theForkShowsTheReplayedTurnsOfTheSource() async throws {
        let connected = try await ForkFixtures.connect(resumeSessionScript: ForkFixtures.replay)
        defer { await connected.model.disconnect() }
        _ = try await connected.model.newSession(ForkFixtures.sourceRequest)

        let fork = try await connected.model.forkSession(testSession)

        #expect(fork.agentMessageTexts == [ForkFixtures.replayedText])
    }

    @Test func aRefusedReplayClosesTheForkAndThrowsItsError() async throws {
        let connected = try await ForkFixtures.connect(resumeSessionError: ForkFixtures.resumeRefusal)
        defer { await connected.model.disconnect() }
        let source = try await connected.model.newSession(ForkFixtures.sourceRequest)

        await #expect(throws: ForkFixtures.resumeRefusal) {
            try await connected.model.forkSession(testSession)
        }
        #expect(connected.model.openSessions.map(ObjectIdentifier.init) == [ObjectIdentifier(source)])
    }

    @Test func aConnectionThatClosesAfterTheForkAnswerRegistersNoSession() async throws {
        let answerGate = UpdateGate()
        let connected = try await ForkFixtures.connect(forkSessionGate: answerGate)
        defer { await connected.model.disconnect() }
        _ = try await connected.model.newSession(ForkFixtures.sourceRequest)
        let requestEvents = try #require(connected.model.connection).subscribeToOutgoingRequests()
        let executor = HoldableTaskExecutor()
        let forking = HeldRequest.run(on: executor) { [model = connected.model] in
            try await model.forkSession(testSession)
        }
        // The task sends the request, and the gate holds the answer. When the
        // task ends or the connection closes first, the request never comes.
        let forkingEnd = TaskEnd(of: forking)
        try await waitUntil { connected.receivedMethods.contains(ClientRequestSpan.Method.forkSession) } orFailWhen: {
            forkingEnd.hasEnded || connected.isConnectionClosed
        }

        // The executor holds the part of the call that follows the answer, so
        // the close of the connection always comes before `forkSession` reads
        // the answer.
        try await executor.whileHeld {
            answerGate.open()
            #expect(await HeldRequest.finished(ClientRequestSpan.Method.forkSession, in: requestEvents))
            connected.agentEnd.close()
            try await waitUntil { connected.model.state == .disconnected } orFailWhen: { connected.isConnectionFailed }
        }

        await #expect(throws: ConnectionError.closed) {
            try await forking.value
        }
        #expect(connected.model.openSessions.isEmpty)
    }
}
