import FoundationModelsACP

/// One `_mcp_server_status` session update of the agent: the last status of
/// one MCP server of the session.
///
/// ACP v2 alpha.7 has no session update for the status of an MCP server, so
/// the FoundationModelsACPAgent session sends this extension update, and it
/// arrives as `SessionUpdate.unknown`. The agent sends one update for each
/// server, after the response of `session/new` and `session/resume`. It
/// sends the updates directly on the connection, so no replay gives them.
///
/// The members of the update:
///
/// - `name` (string, required): the key of the server.
/// - `transport` (optional): `"stdio"` or `"http"`. The agent does not send
///   it for a server that the client sent with a transport that the agent
///   does not know.
/// - `origin` (required): `"client"` or `"config"`.
/// - `status` (required): `"connecting"`, `"connected"`, `"failed"` or
///   `"closed"`.
/// - `reason` (string, optional): why the connection failed. Only a
///   `"failed"` status keeps it.
struct MCPServerStatusUpdate {
    /// The `sessionUpdate` value of the extension update.
    static let kind = "_mcp_server_status"

    /// The name of the server.
    let name: String

    /// The transport of the server, or `nil` when the update has no
    /// `transport` member.
    let transport: MCPServerTransport?

    /// The source of the server.
    let origin: MCPServerOrigin

    /// The status that the agent reports for the server.
    let status: MCPServerStatus

    /// Tells whether an update is an `_mcp_server_status` update, also when
    /// ``decode(_:)`` ignores it.
    ///
    /// - Parameter update: The session update.
    /// - Returns: `true` only for an update with the kind
    ///   `_mcp_server_status`. Each other update, also an unknown update of
    ///   another kind, gives `false`, so it goes to the merge engine.
    static func isStatusUpdate(_ update: SessionUpdate) -> Bool {
        payload(of: update) != nil
    }

    /// Reads an `_mcp_server_status` update from the raw JSON of a
    /// `SessionUpdate.unknown`.
    ///
    /// The decode ignores a member that it does not know. It ignores the
    /// whole update when a required member is missing or is not a string,
    /// or when `origin` or `status` has a value that this client does not
    /// know. A missing `transport` gives no transport. A `transport` that is
    /// present, but is not a string or has a value that this client does not
    /// know, makes the decode ignore the whole update. A `reason` that is not
    /// a string counts as no reason.
    ///
    /// - Parameter update: The session update.
    /// - Returns: The status update, or `nil` for each other update and for
    ///   each status update that the decode ignores.
    static func decode(_ update: SessionUpdate) -> MCPServerStatusUpdate? {
        guard case .object(let members)? = payload(of: update),
            case .string(let name) = members["name"],
            case .string(let originValue) = members["origin"],
            let origin = MCPServerOrigin(wireValue: originValue),
            case .string(let statusValue) = members["status"],
            let status = MCPServerStatus(wireValue: statusValue, reason: reason(in: members))
        else {
            return nil
        }
        let transportMember = members["transport"]
        let transport = transportMember.flatMap(knownTransport(of:))
        guard transportMember == nil || transport != nil else { return nil }
        return MCPServerStatusUpdate(name: name, transport: transport, origin: origin, status: status)
    }

    /// Gives the raw payload of an update when its kind is exactly
    /// `_mcp_server_status`.
    ///
    /// The comparison is case-sensitive. Each other kind gives `nil`, so the
    /// caller does not take an update of another kind.
    ///
    /// - Parameter update: The session update.
    /// - Returns: The payload of the update, or `nil` for each update of
    ///   another kind.
    private static func payload(of update: SessionUpdate) -> JSONValue? {
        guard case .unknown(let updateKind, let payload) = update, updateKind == kind else { return nil }
        return payload
    }

    /// Reads the transport of a `transport` member that is present.
    ///
    /// - Parameter value: The value of the member.
    /// - Returns: The transport, or `nil` when the value is not a string or
    ///   has a value that this client does not know.
    private static func knownTransport(of value: JSONValue) -> MCPServerTransport? {
        guard case .string(let wireValue) = value else { return nil }
        return MCPServerTransport(wireValue: wireValue)
    }

    /// Reads the optional `reason` member of an update.
    ///
    /// - Parameter members: The members of the update.
    /// - Returns: The reason, or `nil` when the member is missing or is not a
    ///   string.
    private static func reason(in members: [String: JSONValue]) -> String? {
        guard case .string(let reason) = members["reason"] else { return nil }
        return reason
    }
}
