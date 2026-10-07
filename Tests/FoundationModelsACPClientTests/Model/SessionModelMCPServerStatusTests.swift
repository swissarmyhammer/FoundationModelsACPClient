import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPClient

// The tests of the `_mcp_server_status` extension update of the agent. ACP
// v2 alpha.7 has no session update for the status of an MCP server, so the
// update arrives as `SessionUpdate.unknown`. The model applies it to
// `mcpServers` and never gives it to the merge engine, so it adds no
// transcript entry.
//
// Each update goes through the real wire decode: the fixtures encode the
// members of the update as JSON and decode a `SessionUpdate` from it.

/// The fixtures of the MCP server status tests.
private enum StatusFixtures {
    /// The wire kind of the extension update.
    static let kind = "_mcp_server_status"

    /// The name of the stdio server that the client sends.
    static let filesName = "files"

    /// The name of the HTTP server that the client sends.
    static let docsName = "docs"

    /// The name of a server that only the configuration of the agent gives.
    static let searchName = "search"

    /// The reason of the failed update of the example.
    static let reason = "The command is not an absolute path."

    /// The stdio server that the client sends.
    static let filesServer = MCPServer.stdio(
        MCPServerStdio(command: AbsolutePath(rawValue: "/usr/local/bin/files-mcp"), name: filesName)
    )

    /// The HTTP server that the client sends.
    static let docsServer = MCPServer.http(MCPServerHTTP(name: docsName, url: "https://example.com/mcp"))

    /// The members of the example update: the `files` stdio server of the
    /// client failed, with a reason.
    static let exampleMembers: [String: JSONValue] = [
        "name": .string(filesName),
        "transport": .string("stdio"),
        "origin": .string("client"),
        "status": .string("failed"),
        "reason": .string(reason),
    ]

    /// Makes a status update from its members, through the wire decode.
    ///
    /// - Parameter members: The members of the update, without the
    ///   `sessionUpdate` discriminator.
    /// - Returns: The decoded update.
    /// - Throws: `EncodingError` or `DecodingError` when the JSON does not
    ///   round-trip.
    static func update(_ members: [String: JSONValue]) throws -> SessionUpdate {
        var object = members
        object["sessionUpdate"] = .string(kind)
        let data = try JSONEncoder().encode(JSONValue.object(object))
        return try JSONDecoder().decode(SessionUpdate.self, from: data)
    }

    /// Makes a status update of the `files` stdio server of the client.
    ///
    /// - Parameter status: The wire value of the status.
    /// - Returns: The decoded update.
    /// - Throws: `EncodingError` or `DecodingError` when the JSON does not
    ///   round-trip.
    static func filesUpdate(status: String) throws -> SessionUpdate {
        var members = exampleMembers
        members["status"] = .string(status)
        members["reason"] = nil
        return try update(members)
    }

    /// Makes a status update of the `search` server, which only the
    /// configuration of the agent gives.
    ///
    /// - Parameters:
    ///   - transport: The wire value of the transport.
    ///   - status: The wire value of the status.
    /// - Returns: The decoded update.
    /// - Throws: `EncodingError` or `DecodingError` when the JSON does not
    ///   round-trip.
    static func searchUpdate(transport: String, status: String) throws -> SessionUpdate {
        try update([
            "name": .string(searchName),
            "transport": .string(transport),
            "origin": .string("config"),
            "status": .string(status),
        ])
    }

    /// Makes the example update with one member changed or removed.
    ///
    /// - Parameters:
    ///   - key: The member to change.
    ///   - value: The new value, or `nil` to remove the member.
    /// - Returns: The decoded update.
    /// - Throws: `EncodingError` or `DecodingError` when the JSON does not
    ///   round-trip.
    static func exampleUpdate(setting key: String, to value: JSONValue?) throws -> SessionUpdate {
        var members = exampleMembers
        members[key] = value
        return try update(members)
    }

    /// Makes a model that holds the two servers of the client, `docs` and
    /// then `files`, and that applies each update at once.
    ///
    /// - Returns: The model.
    @MainActor
    static func modelWithClientServers() -> SessionModel {
        let model = SessionModelFixtures.immediateModel()
        model.setMCPServers([docsServer, filesServer])
        return model
    }

    /// Gives the name and the status of each MCP server item, in list order.
    ///
    /// - Parameter model: The model.
    /// - Returns: One pair for each item.
    @MainActor
    static func statuses(of model: SessionModel) -> [NameAndStatus] {
        model.mcpServers.map { NameAndStatus(name: $0.name, status: $0.status) }
    }
}

/// The name and the status of one MCP server item, as a value that a test
/// can compare.
private struct NameAndStatus: Equatable {
    /// The name of the server.
    let name: String

    /// The status of the server.
    let status: MCPServerStatus
}

/// The MCP server status tests, in one suite so that `swift test --filter
/// SessionModelMCPServerStatusTests` selects them. A tap that never yields
/// would suspend forever, so the suite has a time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionModelMCPServerStatusTests {
    // MARK: - Apply

    @Test func aStatusUpdateSetsTheStatusOfItsServer() throws {
        let model = StatusFixtures.modelWithClientServers()

        model.apply(try StatusFixtures.filesUpdate(status: "connected"))

        #expect(
            StatusFixtures.statuses(of: model) == [
                NameAndStatus(name: StatusFixtures.docsName, status: .notReported),
                NameAndStatus(name: StatusFixtures.filesName, status: .connected),
            ]
        )
    }

    @Test func aLaterUpdateReplacesTheStatus() throws {
        let model = StatusFixtures.modelWithClientServers()

        model.applyEach([
            try StatusFixtures.filesUpdate(status: "connecting"),
            try StatusFixtures.filesUpdate(status: "connected"),
            try StatusFixtures.filesUpdate(status: "closed"),
        ])

        #expect(model.mcpServers.map(\.status) == [.notReported, .closed])
    }

    @Test func aFailedUpdateKeepsItsReason() throws {
        let model = StatusFixtures.modelWithClientServers()

        model.apply(try StatusFixtures.update(StatusFixtures.exampleMembers))

        #expect(model.mcpServers.map(\.status) == [.notReported, .failed(reason: StatusFixtures.reason)])
    }

    @Test func aFailedUpdateWithNoReasonHasNoReason() throws {
        let model = StatusFixtures.modelWithClientServers()

        model.apply(try StatusFixtures.filesUpdate(status: "failed"))

        #expect(model.mcpServers.map(\.status) == [.notReported, .failed(reason: nil)])
    }

    @Test func aReasonOnAnotherStatusIsIgnored() throws {
        let model = StatusFixtures.modelWithClientServers()

        model.apply(try StatusFixtures.exampleUpdate(setting: "status", to: .string("connected")))

        #expect(model.mcpServers.map(\.status) == [.notReported, .connected])
    }

    @Test func aConfigServerUpdateAddsAnItem() throws {
        let model = StatusFixtures.modelWithClientServers()

        model.apply(try StatusFixtures.searchUpdate(transport: "http", status: "connected"))

        let added = try #require(model.mcpServers.last)
        #expect(model.mcpServers.map(\.name) == [StatusFixtures.docsName, StatusFixtures.filesName, StatusFixtures.searchName])
        #expect(added.transport == .http)
        #expect(added.origin == .config)
        #expect(added.server == nil)
        #expect(added.status == .connected)
    }

    @Test func aSecondUpdateOfAConfigServerAddsNoSecondItem() throws {
        let model = SessionModelFixtures.immediateModel()

        model.applyEach([
            try StatusFixtures.searchUpdate(transport: "stdio", status: "connected"),
            try StatusFixtures.searchUpdate(transport: "stdio", status: "closed"),
        ])

        #expect(StatusFixtures.statuses(of: model) == [NameAndStatus(name: StatusFixtures.searchName, status: .closed)])
    }

    // MARK: - Ignore

    @Test func anUnknownStatusValueChangesNothing() throws {
        let model = StatusFixtures.modelWithClientServers()

        model.apply(try StatusFixtures.filesUpdate(status: "sleeping"))

        #expect(model.mcpServers.map(\.status) == [.notReported, .notReported])
        #expect(model.transcript.isEmpty)
    }

    @Test(arguments: [
        ("transport", JSONValue.string("sse")),
        ("origin", JSONValue.string("plugin")),
        ("status", JSONValue.bool(true)),
        ("name", JSONValue.null),
    ])
    func anUnknownOrWrongValueOfARequiredMemberChangesNothing(key: String, value: JSONValue) throws {
        let model = StatusFixtures.modelWithClientServers()

        model.apply(try StatusFixtures.exampleUpdate(setting: key, to: value))

        #expect(model.mcpServers.map(\.status) == [.notReported, .notReported])
        #expect(model.transcript.isEmpty)
    }

    @Test(arguments: ["name", "transport", "origin", "status"])
    func aMissingRequiredMemberChangesNothing(key: String) throws {
        let model = StatusFixtures.modelWithClientServers()

        model.apply(try StatusFixtures.exampleUpdate(setting: key, to: nil))

        #expect(model.mcpServers.map(\.status) == [.notReported, .notReported])
        #expect(model.transcript.isEmpty)
    }

    @Test func anUnknownMemberIsIgnored() throws {
        let model = StatusFixtures.modelWithClientServers()

        model.apply(try StatusFixtures.exampleUpdate(setting: "uptime", to: .string("ten minutes")))

        #expect(model.mcpServers.map(\.status) == [.notReported, .failed(reason: StatusFixtures.reason)])
    }

    // MARK: - Transcript and tap

    @Test func aStatusUpdateAddsNoTranscriptEntry() throws {
        let model = StatusFixtures.modelWithClientServers()

        model.applyEach([
            try StatusFixtures.update(StatusFixtures.exampleMembers),
            agentChunk(text: "Hello"),
        ])

        #expect(model.transcript.map(\.id) == [.wire(.agentMessage(MessageId(rawValue: "agent-1")))])
    }

    @Test(arguments: ["future_update", "_mcp_server_status_v2", "_MCP_SERVER_STATUS"])
    func anUnknownUpdateOfAnotherKindAddsItsUnknownEntry(kind: String) throws {
        let model = StatusFixtures.modelWithClientServers()
        let payload = JSONValue.object(StatusFixtures.exampleMembers)

        model.apply(.unknown(kind, payload))

        let entry = try #require(model.transcript.first?.unknown)
        #expect(model.transcript.count == 1)
        #expect(entry.type == kind)
        #expect(entry.raw == payload)
        #expect(model.mcpServers.map(\.status) == [.notReported, .notReported])
    }

    @Test func theUpdateTapGivesTheRawStatusUpdate() async throws {
        let model = StatusFixtures.modelWithClientServers()
        var tap = model.updateTap().makeAsyncIterator()
        let update = try StatusFixtures.update(StatusFixtures.exampleMembers)

        model.apply(update)

        #expect(await tap.next() == update)
    }
}
