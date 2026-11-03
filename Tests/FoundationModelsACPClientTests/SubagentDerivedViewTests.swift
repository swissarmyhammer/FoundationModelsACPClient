import FoundationModelsACP
import Observation
import Synchronization
import Testing

@testable import FoundationModelsACPClient

// The tests of the derived views of the child tree: `ancestors`, `siblingsIncludingSelf`,
// `descendants`, `SessionPathEntry` and `needsAttention`. Each value follows
// one rule at every level: depth is not a case, and a chain of two or four
// sessions is only the size of a test.

/// Makes the id of a child session from a name.
private func sessionId(_ name: String) -> SessionId {
    SessionId(rawValue: name)
}

/// Makes a `subagent_update` that announces a child with a title.
private func announcement(_ name: String, title: String? = nil) -> SessionUpdate {
    .subagentUpdate(
        SubagentUpdate(sessionId: sessionId(name), title: title.map { .value($0) } ?? .unchanged)
    )
}

/// The permission request of a session.
private func permissionRequest(for session: SessionId) -> RequestPermissionRequest {
    RequestPermissionRequest(
        options: [PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))],
        sessionId: session,
        title: "Run"
    )
}

/// The derived-view tests, in one suite so that `swift test --filter
/// SubagentDerivedViewTests` selects them.
@MainActor
struct SubagentDerivedViewTests {
    /// Connects a model and announces a chain of nested children.
    ///
    /// - Parameter length: The number of sessions in the chain.
    /// - Returns: The connection, and the chain from the first child to the
    ///   deepest.
    private func connectChain(length: Int) async throws -> (ConnectedStub<MailOrderStubAgent>, [SessionModel]) {
        let connected = try await ConnectedStub.make { MailOrderStubAgent(connection: $0, messageIds: []) }
        var chain: [SessionModel] = []
        var parent = testSession
        for level in 1...length {
            let name = "chain-\(level)"
            chain.append(try await connected.announce(announcement(name), child: sessionId(name), in: parent))
            parent = sessionId(name)
        }
        return (connected, chain)
    }

    // MARK: - Ancestors

    @Test func ancestorsAreRootFirstAndEachIsTheParentOfTheNext() async throws {
        let (connected, chain) = try await connectChain(length: 2)
        defer { await connected.model.disconnect() }

        #expect(chain[1].ancestors.map(\.sessionId) == [testSession, sessionId("chain-1")])
    }

    @Test func aRootSessionHasNoAncestors() async throws {
        let connected = try await ConnectedStub.make { MailOrderStubAgent(connection: $0, messageIds: []) }
        defer { await connected.model.disconnect() }

        #expect(connected.root.ancestors.isEmpty)
    }

    // MARK: - Siblings

    @Test func siblingsAreInAnnounceOrder() async throws {
        let connected = try await ConnectedStub.make { MailOrderStubAgent(connection: $0, messageIds: []) }
        defer { await connected.model.disconnect() }
        try await connected.announce(announcement("second"), child: sessionId("second"))
        let first = try await connected.announce(announcement("first"), child: sessionId("first"))

        #expect(first.siblingsIncludingSelf.map(\.sessionId) == [sessionId("second"), sessionId("first")])
    }

    @Test func theSiblingsOfARootSessionAreTheRootSessionsOfTheConnection() async throws {
        let connected = try await ConnectedStub.make { MailOrderStubAgent(connection: $0, messageIds: []) }
        defer { await connected.model.disconnect() }

        #expect(connected.root.siblingsIncludingSelf.map(\.sessionId) == [testSession])
    }

    // MARK: - Descendants

    @Test func descendantsAreDepthFirstInAnnounceOrder() async throws {
        let connected = try await ConnectedStub.make { MailOrderStubAgent(connection: $0, messageIds: []) }
        defer { await connected.model.disconnect() }
        try await connected.announce(announcement("a"), child: sessionId("a"))
        try await connected.announce(announcement("b"), child: sessionId("b"))
        for parent in ["a", "b"] {
            for leaf in ["1", "2"] {
                try await connected.announce(
                    announcement(parent + leaf),
                    child: sessionId(parent + leaf),
                    in: sessionId(parent)
                )
            }
        }

        #expect(
            connected.root.descendants.map(\.sessionId.rawValue) == ["a", "a1", "a2", "b", "b1", "b2"]
        )
    }

    @Test func aRemovedChildIsNotInTheDescendants() async throws {
        let (connected, chain) = try await connectChain(length: 2)
        defer { await connected.model.disconnect() }

        chain[0].removeFromParent()

        #expect(connected.root.descendants.isEmpty)
        #expect(connected.root.children.isEmpty)
        #expect(chain[0].isClosed)
    }

    // MARK: - Path

    @Test func thePathOfADescendantIsTheTitlesOfItsAncestorsPlusItsOwn() async throws {
        let connected = try await ConnectedStub.make { MailOrderStubAgent(connection: $0, messageIds: []) }
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(announcement("c1", title: "Reader"), child: sessionId("c1"))
        let nested = try await connected.announce(
            announcement("c2", title: "Parser"),
            child: sessionId("c2"),
            in: sessionId("c1")
        )

        let entry = try #require(connected.root.descendants.last)

        #expect(entry.path == nested.ancestors.map(\.title) + ["Parser"])
        #expect(entry.path.suffix(2) == ["Reader", "Parser"])
        #expect(child.pathEntry.path.last == "Reader")
    }

    @Test func aChildWithNoTitleShowsItsSessionIdInThePath() async throws {
        let (connected, chain) = try await connectChain(length: 1)
        defer { await connected.model.disconnect() }

        #expect(chain[0].pathEntry.title == "chain-1")
    }

    // MARK: - Entry fields

    @Test func anEntryCarriesTheWorkStateAndNoPendingRequest() async throws {
        let connected = try await ConnectedStub.make { MailOrderStubAgent(connection: $0, messageIds: []) }
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(
            .subagentUpdate(SubagentUpdate(sessionId: sessionId("c"), state: .value(.running(RunningStateUpdate())))),
            child: sessionId("c")
        )

        let entry = child.pathEntry

        #expect(entry.sessionId == sessionId("c"))
        #expect(entry.workState == .running)
        #expect(entry.pendingRequestCount == 0)
        #expect(!entry.needsAttention)
    }

    @Test func aRequiresActionStateNeedsAttention() async throws {
        let connected = try await ConnectedStub.make { MailOrderStubAgent(connection: $0, messageIds: []) }
        defer { await connected.model.disconnect() }
        let child = try await connected.announce(
            .subagentUpdate(
                SubagentUpdate(sessionId: sessionId("c"), state: .value(.requiresAction(RequiresActionStateUpdate())))
            ),
            child: sessionId("c")
        )

        #expect(child.needsAttention)
        #expect(connected.root.needsAttention)
    }

    // MARK: - Needs attention

    @Test(arguments: [2, 4])
    func aPendingRequestRaisesNeedsAttentionOnEveryAncestorAndFallsWhenAnswered(chainLength: Int) async throws {
        let (connected, chain) = try await connectChain(length: chainLength)
        defer { await connected.model.disconnect() }
        let deepest = try #require(chain.last)

        let task = connected.agent.startPermission(permissionRequest(for: deepest.sessionId))
        defer { task.cancel() }
        try await waitForObservation { !deepest.pendingPermissions.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(deepest.pendingRequestCount == 1)
        #expect(connected.root.needsAttention)
        #expect(chain.allSatisfy { $0.needsAttention })
        #expect(connected.root.descendants.last?.pendingRequestCount == 1)

        let pending = try #require(deepest.pendingPermissions.first)
        await deepest.selectPermission(pending.id, option: PermissionOptionId(rawValue: "allow"))

        #expect(!connected.root.needsAttention)
        #expect(chain.allSatisfy { !$0.needsAttention })
    }

    // MARK: - Observation

    @Test func aNewChildFiresTheObservationOfDescendants() async throws {
        let connected = try await ConnectedStub.make { MailOrderStubAgent(connection: $0, messageIds: []) }
        defer { await connected.model.disconnect() }
        let fired = Mutex(false)
        withObservationTracking {
            _ = connected.root.descendants
        } onChange: {
            fired.withLock { $0 = true }
        }

        try await connected.announce(announcement("c"), child: sessionId("c"))

        #expect(fired.withLock { $0 })
    }

    @Test func aPendingRequestOfADescendantFiresTheObservationOfNeedsAttention() async throws {
        let (connected, chain) = try await connectChain(length: 2)
        defer { await connected.model.disconnect() }
        let deepest = try #require(chain.last)
        let fired = Mutex(false)
        withObservationTracking {
            _ = connected.root.needsAttention
        } onChange: {
            fired.withLock { $0 = true }
        }

        let task = connected.agent.startPermission(permissionRequest(for: deepest.sessionId))
        defer { task.cancel() }
        try await waitForObservation { !deepest.pendingPermissions.isEmpty } orFailWhen: { connected.root.isClosed }

        #expect(fired.withLock { $0 })
    }

    @Test func aChangeOfTheWorkStateFiresTheObservationOfItsEntry() async throws {
        let (connected, chain) = try await connectChain(length: 1)
        defer { await connected.model.disconnect() }
        let child = chain[0]
        let fired = Mutex(false)
        withObservationTracking {
            _ = child.pathEntry
        } onChange: {
            fired.withLock { $0 = true }
        }

        try await connected.agent.send(.stateUpdate(.running(RunningStateUpdate())), to: child.sessionId)
        try await waitForObservation { child.workState == .running } orFailWhen: { connected.root.isClosed }

        #expect(fired.withLock { $0 })
    }
}
