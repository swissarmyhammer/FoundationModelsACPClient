import CloudKit
import FoundationModelsACP
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPClient

// The tests of the identity of the person that `initialize` sends in its
// `_meta`, and of the identity sources. Each test uses a fake source or
// injected CloudKit closures, so no test touches `CKContainer`.

/// A source that always gives one actor.
private struct FakeIdentitySource: PersonIdentitySource {
    /// The actor that the source gives.
    let actor: GraphQLActor

    func resolve() async -> GraphQLActor {
        actor
    }
}

/// The fixtures of the identity tests.
private enum IdentityFixtures {
    /// The actor of the fake source.
    static let person = GraphQLActor(id: "person-1", name: "Pat Person", aliases: ["local/pat"])

    /// An actor that a caller puts in the `_meta` of its request.
    static let callerActor = GraphQLActor(id: "caller-1", name: "Caller")

    /// The local user of the iCloud source tests.
    static let local = LocalUserIdentitySource(userName: "pat", fullUserName: "Pat Person")

    /// The `_meta` key of the actor.
    static let key = GraphQLActor.initializeMetaKey

    /// Connects a model with the fake source to a stub agent.
    ///
    /// - Parameter logLines: The recorded log lines of the model.
    /// - Returns: The connected model.
    @MainActor
    static func connect(logLines: ThreadSafeBuffer<String> = ThreadSafeBuffer()) async -> ConnectedModel {
        let model = ConnectionModel(
            logger: ACPLogger { logLines.append($0) },
            identitySource: FakeIdentitySource(actor: person)
        )
        return await ConnectedModel(model: model) { connection in
            ScriptedStubAgent(connection: connection, session: testSession, script: [])
        }
    }

    /// Gives the `_meta` object of the one `initialize` that the agent got.
    ///
    /// - Parameter connected: The connected model.
    /// - Returns: The members of the `_meta` object, or `nil` when it is not
    ///   an object.
    @MainActor
    static func sentMembers(of connected: ConnectedModel) -> [String: JSONValue]? {
        guard case .object(let members)? = connected.receivedMeta(of: ClientRequestSpan.Method.initialize).last
        else { return nil }
        return members
    }

    /// Makes an iCloud source with injected CloudKit closures.
    ///
    /// - Parameters:
    ///   - status: Gives the account status.
    ///   - recordName: Gives the record name.
    /// - Returns: The source.
    static func iCloud(
        status: @escaping @Sendable () async throws -> CKAccountStatus,
        recordName: @escaping @Sendable () async throws -> String = { "_icloud-record" }
    ) -> ICloudIdentitySource {
        ICloudIdentitySource(
            containerIdentifier: "iCloud.test",
            local: local,
            accountStatus: status,
            userRecordName: recordName
        )
    }
}

/// The error of an injected CloudKit closure.
private struct InjectedCloudKitError: Error {}

@MainActor
@Suite("ConnectionModel identity at initialize")
struct ConnectionModelIdentityTests {
    @Test func initializeSendsTheActorOfTheSourceInTheMeta() async throws {
        let connected = await IdentityFixtures.connect()
        try await connected.initialize()

        let members = try #require(IdentityFixtures.sentMembers(of: connected))
        let expected = try IdentityFixtures.person.metaValue(as: JSONValue.self)
        #expect(members[IdentityFixtures.key] == expected)
        #expect(connected.model.actor == IdentityFixtures.person)
    }

    @Test func initializeKeepsTheOtherMetaKeysOfTheCaller() async throws {
        let connected = await IdentityFixtures.connect()
        var request = makeInitializeRequest()
        request.meta = .object(["caller/key": .string("value"), "caller/flag": .bool(true)])
        _ = try await connected.model.initialize(request)

        let members = try #require(IdentityFixtures.sentMembers(of: connected))
        #expect(members["caller/key"] == .string("value"))
        #expect(members["caller/flag"] == .bool(true))
        #expect(members[IdentityFixtures.key] == (try IdentityFixtures.person.metaValue(as: JSONValue.self)))
    }

    @Test func initializeKeepsTheActorOfTheCaller() async throws {
        let connected = await IdentityFixtures.connect()
        let callerValue = try IdentityFixtures.callerActor.metaValue(as: JSONValue.self)
        var request = makeInitializeRequest()
        request.meta = .object([IdentityFixtures.key: callerValue])
        _ = try await connected.model.initialize(request)

        let members = try #require(IdentityFixtures.sentMembers(of: connected))
        #expect(members[IdentityFixtures.key] == callerValue)
        #expect(connected.model.actor == IdentityFixtures.callerActor)
    }

    @Test func initializeKeepsAMetaThatIsNotAnObjectAndLogsOneWarning() async throws {
        let logLines = ThreadSafeBuffer<String>()
        let connected = await IdentityFixtures.connect(logLines: logLines)
        var request = makeInitializeRequest()
        request.meta = .string("not an object")
        _ = try await connected.model.initialize(request)

        #expect(connected.receivedMeta(of: ClientRequestSpan.Method.initialize).last == .string("not an object"))
        #expect(connected.model.actor == nil)
        #expect(logLines.elements.filter { $0.contains("not a JSON object") }.count == 1)
    }
}

@Suite("Identity sources")
struct IdentitySourceTests {
    @Test func localSourceGivesTheLocalIdAndTheFullName() async {
        let actor = await IdentityFixtures.local.resolve()
        #expect(actor == GraphQLActor(id: "local/pat", name: "Pat Person"))
    }

    @Test func iCloudSourceGivesTheRecordNameWhenTheAccountIsAvailable() async {
        let actor = await IdentityFixtures.iCloud(status: { .available }).resolve()
        #expect(actor == GraphQLActor(id: "_icloud-record", name: "Pat Person", aliases: ["local/pat"]))
    }

    @Test(arguments: [
        CKAccountStatus.noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable,
    ])
    func iCloudSourceFallsBackWhenTheAccountIsNotAvailable(status: CKAccountStatus) async {
        let source = IdentityFixtures.iCloud(status: { status }, recordName: { Issue.record("no record read"); return "x" })
        #expect(await source.resolve() == IdentityFixtures.local.actor)
    }

    @Test func iCloudSourceFallsBackWhenTheStatusThrows() async {
        let source = IdentityFixtures.iCloud(status: { throw InjectedCloudKitError() })
        #expect(await source.resolve() == IdentityFixtures.local.actor)
    }

    @Test func iCloudSourceFallsBackWhenTheRecordIdThrows() async {
        let source = IdentityFixtures.iCloud(status: { .available }, recordName: { throw InjectedCloudKitError() })
        #expect(await source.resolve() == IdentityFixtures.local.actor)
    }

    @Test func iCloudSourceFallsBackWhenTheRecordNameIsEmpty() async {
        let source = IdentityFixtures.iCloud(status: { .available }, recordName: { "" })
        #expect(await source.resolve() == IdentityFixtures.local.actor)
    }
}
