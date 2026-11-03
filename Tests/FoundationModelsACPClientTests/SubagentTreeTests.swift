import FoundationModelsACP
import Observation
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// The tests of the child session tree of `ConnectionModel`. The unstable
// `subagent_update` update announces a child session. The model makes one
// `SessionModel` for the child, links it to its parent, and routes the
// updates and the requests of the child id to it.
//
// The model is parent and child all the way down. Every session is the same
// kind of thing, so each rule holds at each level. A chain of three sessions
// is only the size of the tests.

/// The ids of the child sessions of the tests.
private let grandChild = SessionId(rawValue: "grandchild-1")

/// A model that is connected to a mail-order stub agent, with one open root
/// session. The test sends the child updates itself.
@MainActor
private struct SubagentConnection {
    let connected: ConnectedStub<MailOrderStubAgent>

    var model: ConnectionModel { connected.model }
    var agent: MailOrderStubAgent { connected.agent }
    var root: SessionModel { connected.root }

    /// Connects the model and opens the root session.
    ///
    /// - Throws: The error of `initialize` or of `session/new`.
    static func make() async throws -> Self {
        Self(connected: try await ConnectedStub.make { MailOrderStubAgent(connection: $0, messageIds: []) })
    }

    /// Announces a child session in the stream of its parent, and waits
    /// until the model made the child.
    ///
    /// - Parameters:
    ///   - child: The update that announces the child.
    ///   - parent: The parent session.
    /// - Returns: The model of the child.
    /// - Throws: ``WaitEndedOnFailure`` when the root session closed first.
    @discardableResult
    func announce(_ child: SubagentUpdate, in parent: SessionId = testSession) async throws -> SessionModel {
        try await connected.announce(.subagentUpdate(child), child: child.sessionId, in: parent)
    }
}

/// Tells if an asynchronous write fires the observation of a read.
///
/// - Parameters:
///   - read: The reads that the observation tracks.
///   - write: The write to make after the tracking starts.
/// - Returns: `true` when the write fired `onChange`.
@MainActor
private func observationFiresAsync(
    reading read: () -> Void,
    during write: () async -> Void
) async -> Bool {
    let fired = Mutex(false)
    withObservationTracking(read) {
        fired.withLock { $0 = true }
    }
    await write()
    return fired.withLock { $0 }
}

/// The tests of the child tree, in one suite so that `swift test --filter
/// SubagentTreeTests` selects them.
@MainActor
struct SubagentTreeTests {
    // MARK: - Tree

    @Test func aSubagentUpdateMakesAChildThatKnowsItsParent() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }

        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))

        #expect(child.parent === connected.root)
        #expect(connected.root.children.map(\.id) == [firstChild])
    }

    @Test func childrenAreInAnnounceOrder() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }

        try await connected.announce(SubagentUpdate(sessionId: secondChild))
        try await connected.announce(SubagentUpdate(sessionId: firstChild))

        #expect(connected.root.children.map(\.id) == [secondChild, firstChild])
    }

    @Test func aChildOfAChildWorksByTheSameRule() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }

        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))
        let nested = try await connected.announce(SubagentUpdate(sessionId: grandChild), in: firstChild)

        #expect(nested.parent === child)
        #expect(child.children.map(\.id) == [grandChild])
        #expect(connected.root.children.map(\.id) == [firstChild])
    }

    @Test func aRepeatedAnnouncementKeepsTheSameChildObject() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild, title: .value("one")))

        try await connected.agent.send(.subagentUpdate(SubagentUpdate(sessionId: firstChild, title: .value("two"))))
        try await waitForObservation { child.title == "two" } orFailWhen: { connected.root.isClosed }

        #expect(connected.root.children.count == 1)
        #expect(connected.root.children.first === child)
    }

    // MARK: - Patch rules

    @Test func aValueReplacesAndAnOmittedFieldStaysAndNullClears() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(
            SubagentUpdate(sessionId: firstChild, description: .value("reads"), title: .value("Reader"))
        )

        try await connected.agent.send(.subagentUpdate(SubagentUpdate(sessionId: firstChild, title: .value("Writer"))))
        try await waitForObservation { child.title == "Writer" } orFailWhen: { connected.root.isClosed }
        #expect(child.description == "reads")

        try await connected.agent.send(.subagentUpdate(SubagentUpdate(sessionId: firstChild, description: .cleared)))
        try await waitForObservation { child.description == nil } orFailWhen: { connected.root.isClosed }
        #expect(child.title == "Writer")
    }

    @Test func theCwdAndTheAdditionalDirectoriesFollowThePatchRules() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let work = AbsolutePath(rawValue: "/work")
        let extra = AbsolutePath(rawValue: "/extra")

        let child = try await connected.announce(
            SubagentUpdate(sessionId: firstChild, additionalDirectories: .value([extra]), cwd: .value(work))
        )

        #expect(child.cwd == work)
        #expect(child.additionalDirectories == [extra])
    }

    @Test func capabilitiesReplaceAsAWhole() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let cancelOnly = SubagentSessionCapabilities(cancel: SessionCancelCapabilities())
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild, capabilities: .value(cancelOnly)))
        #expect(child.capabilities == cancelOnly)

        try await connected.agent.send(
            .subagentUpdate(SubagentUpdate(sessionId: firstChild, capabilities: .value(SubagentSessionCapabilities())))
        )
        try await waitForObservation { child.capabilities == SubagentSessionCapabilities() } orFailWhen: {
            connected.root.isClosed
        }

        #expect(child.capabilities?.cancel == nil)
    }

    // MARK: - Work state

    @Test func aChildHasUnknownWorkStateUntilItReportsOne() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }

        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))

        #expect(child.workState == .unknown)
    }

    @Test func theWorkStateFollowsTheStateUpdatesOfTheChild() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))

        try await connected.agent.send(.stateUpdate(.running(RunningStateUpdate())), to: firstChild)
        try await waitForObservation { child.workState == .running } orFailWhen: { connected.root.isClosed }

        try await connected.agent.send(
            .stateUpdate(.idle(IdleStateUpdate(stopReason: .cancelled))),
            to: firstChild
        )
        try await waitForObservation { child.workState == .idle(stopReason: .cancelled, error: nil) } orFailWhen: {
            connected.root.isClosed
        }
    }

    @Test func theStateOfASubagentUpdateSetsTheWorkState() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }

        let child = try await connected.announce(
            SubagentUpdate(sessionId: firstChild, state: .value(.running(RunningStateUpdate())))
        )

        #expect(child.workState == .running)
    }

    @Test func anAnnouncementThatOmitsTheStateDoesNotOverwriteALaterOwnState() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(
            SubagentUpdate(sessionId: firstChild, state: .value(.running(RunningStateUpdate())))
        )
        try await connected.agent.send(.stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn))), to: firstChild)
        try await waitForObservation { child.workState == .idle(stopReason: .endTurn, error: nil) } orFailWhen: {
            connected.root.isClosed
        }

        try await connected.agent.send(.subagentUpdate(SubagentUpdate(sessionId: firstChild, title: .value("Late"))))
        try await waitForObservation { child.title == "Late" } orFailWhen: { connected.root.isClosed }

        #expect(child.workState == .idle(stopReason: .endTurn, error: nil))
    }

    @Test func aLaterAnnouncementWithANewStateReplacesTheOwnStateOfTheChild() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(
            SubagentUpdate(sessionId: firstChild, state: .value(.running(RunningStateUpdate())))
        )
        try await connected.agent.send(.stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn))), to: firstChild)
        try await waitForObservation { child.workState == .idle(stopReason: .endTurn, error: nil) } orFailWhen: {
            connected.root.isClosed
        }

        try await connected.agent.send(
            .subagentUpdate(SubagentUpdate(sessionId: firstChild, state: .value(.requiresAction(RequiresActionStateUpdate()))))
        )
        try await waitForObservation { child.workState == .requiresAction } orFailWhen: { connected.root.isClosed }
    }

    // MARK: - Routing

    @Test func anUpdateWithTheChildIdReachesOnlyTheChild() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))

        try await connected.agent.send(agentChunk(text: "from the child"), to: firstChild)
        try await waitForObservation { !child.transcript.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(connected.root.transcript.isEmpty)
    }

    @Test func anUpdateOfAnUnannouncedChildChangesNoModel() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }

        try await connected.agent.send(agentChunk(text: "lost"), to: secondChild)
        // A later update of the root proves that the earlier update went by.
        try await connected.agent.send(agentChunk(text: "mark", message: "root-1"))
        try await waitForObservation { !connected.root.transcript.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(connected.root.transcript.count == 1)
        #expect(connected.root.children.isEmpty)
    }

    @Test func aSessionMessageGoesToTheTranscriptOfTheOuterSession() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let message = SessionMessage(
            messageId: MessageId(rawValue: "m-1"),
            content: .value([textBlock("hello child")]),
            recipientSessionId: .value(firstChild),
            senderSessionId: .value(testSession)
        )

        try await connected.agent.send(.sessionMessage(message))
        try await waitForObservation { connected.root.transcript.first?.sessionMessage != nil } orFailWhen: {
            connected.root.isClosed
        }

        #expect(connected.root.transcript.first?.sessionMessage?.recipientSessionId == firstChild)
    }

    // MARK: - Cancel

    @Test func cancelOnAChildSendsSessionCancelWithTheChildId() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(
            SubagentUpdate(
                sessionId: firstChild,
                capabilities: .value(SubagentSessionCapabilities(cancel: SessionCancelCapabilities()))
            )
        )

        try await child.cancel()

        var cancels = connected.agent.cancels.makeAsyncIterator()
        // This read has no failure event: `cancels` is a stream of the stub.
        // It hangs when the cancel does not reach the agent. This is a known
        // limit of rule T1.
        #expect(await cancels.next()?.sessionId == firstChild)
    }
}

// MARK: - Requests of a child

extension SubagentTreeTests {
    @Test func aPermissionRequestWithTheChildIdStaysWithTheChild() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))
        let request = RequestPermissionRequest(
            options: [PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))],
            sessionId: firstChild,
            title: "Run"
        )

        let task = connected.agent.startPermission(request)
        defer { task.cancel() }
        try await waitForObservation { !child.pendingPermissions.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(child.pendingPermissions.first?.request.sessionId == firstChild)
        #expect(connected.root.pendingPermissions.isEmpty)
    }

    @Test func anElicitationWithTheChildIdStaysWithTheChild() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))
        let request = ElicitationFixtures.formRequest(scope: .session(ElicitationSessionScope(sessionId: firstChild)))

        let task = connected.agent.startElicitation(request)
        defer { task.cancel() }
        try await waitForObservation { !child.pendingElicitations.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(connected.root.pendingElicitations.isEmpty)
    }

    // MARK: - Refused operations

    @Test func promptOnAChildThrowsWithoutSending() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))

        await #expect(throws: SubagentSessionError.notPermitted(operation: ClientRequestSpan.Method.prompt)) {
            _ = try await child.prompt([textBlock("hi")])
        }
    }

    @Test func cancelOnAChildWithNoCancelCapabilityThrowsWithoutSending() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))

        await #expect(throws: SubagentSessionError.notPermitted(operation: ClientRequestSpan.Method.cancelSession)) {
            try await child.cancel()
        }
    }

    @Test func setConfigOptionOnAChildThrowsWithoutSending() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))
        let request = SetSessionConfigOptionRequest(
            configId: SessionConfigId(rawValue: "mode"),
            sessionId: firstChild,
            value: .id(SessionConfigValueId(rawValue: "fast"))
        )

        await #expect(throws: SubagentSessionError.notPermitted(operation: ClientRequestSpan.Method.setConfigOption)) {
            try await child.setConfigOption(request)
        }
    }

    @Test func closeOnAChildThrowsWithoutSending() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))

        await #expect(throws: SubagentSessionError.notPermitted(operation: ClientRequestSpan.Method.closeSession)) {
            try await connected.model.close(child)
        }
    }

    @Test func slashCommandsOfAChildAreNotOffered() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))
        let command = AvailableCommand.command(Command(description: "Makes a plan", name: "plan"))

        try await connected.agent.send(
            .availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [command])),
            to: firstChild
        )
        // A later update of the child proves that the earlier update went by.
        try await connected.agent.send(agentChunk(text: "mark", message: "child-1"), to: firstChild)
        try await waitForObservation { !child.transcript.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(child.availableCommands == nil)
    }

    // MARK: - Close

    @Test func closingAParentRemovesItsChildrenAtEachLevel() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))
        let nested = try await connected.announce(SubagentUpdate(sessionId: grandChild), in: firstChild)

        connected.root.markClosed()

        #expect(connected.root.children.isEmpty)
        #expect(child.children.isEmpty)
        #expect(child.isClosed && nested.isClosed)
    }

    // MARK: - Session list

    @Test func aSessionListRefreshNeverAddsAChild() async throws {
        let item = SessionInfo(cwd: AbsolutePath(rawValue: "/"), sessionId: firstChild)
        let root = SessionInfo(cwd: AbsolutePath(rawValue: "/"), sessionId: testSession)
        let model = ConnectionModel(coalescingCadence: .zero)
        let connected = await ConnectedModel(model: model) { connection in
            ScriptedStubAgent(
                connection: connection,
                session: testSession,
                script: [],
                capabilities: InitializeFixtures.fullCapabilities,
                sessionListPages: [nil: ListSessionsResponse(sessions: [root, item])]
            )
        }
        try await connected.initialize()
        defer { await model.disconnect() }
        let session = try await model.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: "/")))
        try await connected.agentConnection.sessionUpdate(
            UpdateSessionNotification(
                sessionId: testSession,
                update: .subagentUpdate(SubagentUpdate(sessionId: firstChild))
            )
        )
        try await waitForObservation { !session.children.isEmpty } orFailWhen: { session.isClosed }

        try await model.refreshSessions()

        #expect(model.sessions.map(\.sessionId) == [testSession])
    }

    // MARK: - Observation

    @Test func aNewChildFiresTheObservationOfChildren() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }

        let fired = await observationFiresAsync(reading: { _ = connected.root.children }, during: {
            _ = try? await connected.announce(SubagentUpdate(sessionId: firstChild))
        })

        #expect(fired)
    }

    @Test func aChangeOfTheWorkStateFiresItsObservation() async throws {
        let connected = try await SubagentConnection.make()
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(SubagentUpdate(sessionId: firstChild))

        let fired = await observationFiresAsync(reading: { _ = child.workState }, during: {
            try? await connected.agent.send(.stateUpdate(.running(RunningStateUpdate())), to: firstChild)
            try? await waitForObservation { child.workState == .running } orFailWhen: { connected.root.isClosed }
        })

        #expect(fired)
    }
}
