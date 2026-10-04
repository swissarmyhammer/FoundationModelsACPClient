import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the session list of `ConnectionModel`: `refreshSessions(cwd:)`,
// `loadMoreSessions()`, the patch of a listed session from the
// `session_info_update` of its open model, and `deleteSession(_:)`.
//
// `ConnectedModel` gives the real ACP wire, with a `ScriptedStubAgent` on the
// agent end. The stub answers `session/list` with the page of the cursor of
// each request, can hold a page until the test opens its gate, and records
// each list and delete request.

/// The fixtures of the session list tests.
private enum SessionListFixtures {
    /// The working directory that the list requests filter by.
    static let workingDirectory = AbsolutePath(rawValue: "/work")

    /// The cursor that the first page gives for the second page.
    static let secondPageCursor = SessionListCursor(rawValue: "page-2")

    /// The title that the first page gives the test session.
    static let listedTitle = "Listed title"

    /// The title that the agent gives the test session after the list.
    static let changedTitle = "Changed title"

    /// The test session, as the first page lists it.
    static let firstItem = SessionInfo(cwd: workingDirectory, sessionId: testSession, title: listedTitle)

    /// A session that is never open, as the second page lists it.
    static let secondItem = SessionInfo(cwd: workingDirectory, sessionId: SessionId(rawValue: "session-2"))

    /// The first page: the test session, and the cursor of the second page.
    static let firstPage = ListSessionsResponse(sessions: [firstItem], nextCursor: secondPageCursor)

    /// The second page, which is the last page.
    static let secondPage = ListSessionsResponse(sessions: [secondItem])

    /// The two pages, keyed by the cursor that asks for each one.
    static let twoPages: [SessionListCursor?: ListSessionsResponse] = [
        nil: firstPage,
        secondPageCursor: secondPage,
    ]

    /// The new-session request that opens the test session.
    static let newSessionRequest = NewSessionRequest(cwd: workingDirectory)

    /// The update that changes the title of the test session.
    static let titleChange = SessionUpdate.sessionInfoUpdate(SessionInfoUpdate(title: .value(changedTitle)))

    /// The update that clears the title of the test session.
    static let titleClear = SessionUpdate.sessionInfoUpdate(SessionInfoUpdate(title: .cleared))

    /// The error of a list that the agent does not advertise.
    static let listUnsupported = ConnectionModelError.unsupported(method: ClientRequestSpan.Method.listSessions)

    /// The error of a delete that the agent does not advertise.
    static let deleteUnsupported = ConnectionModelError.unsupported(method: ClientRequestSpan.Method.deleteSession)

    /// The number of list requests that a refresh and one load of more
    /// sessions send.
    static let refreshAndLoadMoreRequestCount = 2

    /// The methods that a delete of an open session sends, in order.
    static let closeThenDelete = [
        ClientRequestSpan.Method.closeSession,
        ClientRequestSpan.Method.deleteSession,
    ]

    /// Connects a model that applies each chunk at once to a stub agent that
    /// pages the session list in ``twoPages``.
    ///
    /// - Parameters:
    ///   - capabilities: The capabilities the agent answers `initialize`
    ///     with.
    ///   - gates: The gate that must open before the page of a cursor
    ///     answers, keyed by that cursor.
    ///   - promptScript: The updates the agent sends during each prompt turn.
    /// - Returns: The connected model, after `initialize`.
    /// - Throws: Whatever `initialize` threw.
    @MainActor
    static func connect(
        capabilities: AgentCapabilities = InitializeFixtures.fullCapabilities,
        gates: [SessionListCursor?: UpdateGate] = [:],
        promptScript: [SessionUpdate] = []
    ) async throws -> ConnectedModel {
        let connected = await ConnectedModel(model: ConnectionModel(coalescingCadence: .zero)) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: promptScript,
                closeSessionError: nil,
                capabilities: capabilities,
                sessionListPages: twoPages,
                sessionListGates: gates
            )
        }
        try await connected.initialize()
        return connected
    }

    /// Gives the title of each listed session of a model, in list order.
    ///
    /// - Parameter model: The connection model.
    /// - Returns: The title of each item, or `nil` for an item with no title.
    @MainActor
    static func titles(of model: ConnectionModel) -> [String?] {
        model.sessions.map(\.title)
    }
}

/// The session list tests of the connection model, in one suite so that
/// `swift test --filter ConnectionModelListTests` selects them. A wait for a
/// request that never comes would suspend for ever, so the suite has a time
/// limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionModelListTests {
    // MARK: - refreshSessions and loadMoreSessions

    @Test func twoPagesLoadInOrderWithTheSameWorkingDirectory() async throws {
        let connected = try await SessionListFixtures.connect()

        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)
        #expect(connected.model.hasMoreSessions)
        try await connected.model.loadMoreSessions()

        #expect(connected.model.sessions == [SessionListFixtures.firstItem, SessionListFixtures.secondItem])
        #expect(!connected.model.hasMoreSessions)
        #expect(connected.listRequests == [
            ListSessionsRequest(cwd: SessionListFixtures.workingDirectory),
            ListSessionsRequest(cursor: SessionListFixtures.secondPageCursor, cwd: SessionListFixtures.workingDirectory),
        ])
    }

    @Test func aRefreshStartsAgainAtTheFirstPageAndReplacesTheList() async throws {
        let connected = try await SessionListFixtures.connect()
        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)
        try await connected.model.loadMoreSessions()

        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)

        #expect(connected.model.sessions == [SessionListFixtures.firstItem])
        #expect(connected.model.hasMoreSessions)
        #expect(connected.listRequests.last == ListSessionsRequest(cwd: SessionListFixtures.workingDirectory))
    }

    @Test func loadMoreWithNoCursorSendsNothing() async throws {
        let connected = try await SessionListFixtures.connect()
        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)
        try await connected.model.loadMoreSessions()

        try await connected.model.loadMoreSessions()
        // A second initialize makes a round trip after the load, so a list
        // request that went out would be in the record before its answer.
        try await connected.initialize()

        #expect(connected.listRequests.count == SessionListFixtures.refreshAndLoadMoreRequestCount)
        #expect(connected.model.sessions == [SessionListFixtures.firstItem, SessionListFixtures.secondItem])
    }

    @Test func aPageOfAnOlderRefreshDoesNotChangeTheList() async throws {
        let pageGate = UpdateGate()
        let connected = try await SessionListFixtures.connect(
            gates: [SessionListFixtures.secondPageCursor: pageGate]
        )
        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)
        let loading = Task { [model = connected.model] in
            try await model.loadMoreSessions()
        }
        try await waitUntil { connected.listRequests.count == SessionListFixtures.refreshAndLoadMoreRequestCount }

        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)
        pageGate.open()
        try await loading.value

        #expect(connected.model.sessions == [SessionListFixtures.firstItem])
        #expect(connected.model.hasMoreSessions)
    }

    // MARK: - session_info_update

    @Test func aTitleChangeOfAnOpenSessionShowsInTheList() async throws {
        let connected = try await SessionListFixtures.connect(promptScript: [SessionListFixtures.titleChange])
        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)
        let session = try await connected.model.newSession(SessionListFixtures.newSessionRequest)

        _ = try await session.prompt([textBlock("Rename")])

        try await waitUntil { session.sessionInfo.title == .value(SessionListFixtures.changedTitle) }
        #expect(SessionListFixtures.titles(of: connected.model) == [SessionListFixtures.changedTitle])
    }

    @Test func aClearedTitleOfAnOpenSessionClearsTheListedTitle() async throws {
        let connected = try await SessionListFixtures.connect(promptScript: [SessionListFixtures.titleClear])
        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)
        let session = try await connected.model.newSession(SessionListFixtures.newSessionRequest)

        _ = try await session.prompt([textBlock("Clear the title")])

        try await waitUntil { session.sessionInfo.title == .cleared }
        #expect(SessionListFixtures.titles(of: connected.model) == [nil])
    }

    // MARK: - deleteSession

    @Test func deleteOfAnOpenSessionSendsCloseThenDeleteAndRemovesTheItem() async throws {
        let connected = try await SessionListFixtures.connect()
        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)
        let session = try await connected.model.newSession(SessionListFixtures.newSessionRequest)

        try await connected.model.deleteSession(testSession)

        let closeThenDelete = SessionListFixtures.closeThenDelete
        #expect(Array(connected.receivedMethods.suffix(closeThenDelete.count)) == closeThenDelete)
        #expect(connected.deleteRequests == [DeleteSessionRequest(sessionId: testSession)])
        #expect(session.isClosed)
        #expect(connected.model.openSessions.isEmpty)
        #expect(connected.model.sessions.isEmpty)
    }

    @Test func deleteOfASessionThatIsNotOpenSendsOnlyDelete() async throws {
        let connected = try await SessionListFixtures.connect()
        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)

        try await connected.model.deleteSession(testSession)

        #expect(!connected.receivedMethods.contains(ClientRequestSpan.Method.closeSession))
        #expect(connected.deleteRequests == [DeleteSessionRequest(sessionId: testSession)])
        #expect(connected.model.sessions.isEmpty)
    }

    // MARK: - Capabilities

    @Test func refreshWithNoCapabilityThrowsUnsupportedAndSendsNothing() async throws {
        let connected = try await SessionListFixtures.connect(capabilities: AgentCapabilities())

        await #expect(throws: SessionListFixtures.listUnsupported) {
            try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)
        }
        // A second initialize makes a round trip after the refused list, so
        // a list that went out would be in the record before its answer.
        try await connected.initialize()

        #expect(connected.listRequests.isEmpty)
    }

    @Test func loadMoreWithNoCapabilityThrowsUnsupportedAndSendsNothing() async throws {
        let connected = try await SessionListFixtures.connect(capabilities: AgentCapabilities())

        await #expect(throws: SessionListFixtures.listUnsupported) {
            try await connected.model.loadMoreSessions()
        }
        try await connected.initialize()

        #expect(connected.listRequests.isEmpty)
    }

    @Test func deleteWithNoCapabilityThrowsUnsupportedAndSendsNothing() async throws {
        let connected = try await SessionListFixtures.connect(capabilities: InitializeFixtures.baselineCapabilities)
        try await connected.model.refreshSessions(cwd: SessionListFixtures.workingDirectory)
        let session = try await connected.model.newSession(SessionListFixtures.newSessionRequest)

        await #expect(throws: SessionListFixtures.deleteUnsupported) {
            try await connected.model.deleteSession(testSession)
        }
        // A second initialize makes a round trip after the refused delete, so
        // a request that went out would be in the record before its answer.
        try await connected.initialize()

        #expect(connected.deleteRequests.isEmpty)
        #expect(!connected.receivedMethods.contains(ClientRequestSpan.Method.closeSession))
        #expect(!session.isClosed)
        #expect(connected.model.sessions == [SessionListFixtures.firstItem])
    }
}
