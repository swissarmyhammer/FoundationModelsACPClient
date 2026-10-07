import FoundationModelsACP
import Observation

/// The transport of an MCP server.
public enum MCPServerTransport: String, Hashable, Sendable {
    /// The agent starts the server as a process and talks to it on its
    /// standard input and output. The wire value is `"stdio"`.
    case stdio

    /// The agent talks to the server over HTTP. The wire value is `"http"`.
    case http

    /// Makes the transport of a wire value.
    ///
    /// - Parameter wireValue: The wire value: `"stdio"` or `"http"`.
    /// - Returns: `nil` for a wire value that this client does not know.
    init?(wireValue: String) {
        self.init(rawValue: wireValue)
    }
}

/// The source of an MCP server of a session.
public enum MCPServerOrigin: String, Hashable, Sendable {
    /// The client sent the server in its `session/new` or `session/resume`
    /// request. The wire value is `"client"`.
    case client

    /// The configuration of the agent gave the server. The wire value is
    /// `"config"`.
    case config

    /// Makes the origin of a wire value.
    ///
    /// - Parameter wireValue: The wire value: `"client"` or `"config"`.
    /// - Returns: `nil` for a wire value that this client does not know.
    init?(wireValue: String) {
        self.init(rawValue: wireValue)
    }
}

/// The last connection status of an MCP server, as the agent reports it.
public enum MCPServerStatus: Hashable, Sendable {
    /// The agent did not report a status for the server yet.
    case notReported

    /// The agent connects to the server.
    case connecting

    /// The agent connected to the server.
    case connected

    /// The connection of the agent to the server failed.
    ///
    /// - Parameter reason: Why the connection failed, or `nil` when the agent
    ///   gave no reason.
    case failed(reason: String?)

    /// The connection of the agent to the server closed.
    case closed

    /// Makes the status of a wire value.
    ///
    /// No wire value gives ``notReported``: only the client uses it.
    ///
    /// - Parameters:
    ///   - wireValue: The wire value: `"connecting"`, `"connected"`,
    ///     `"failed"` or `"closed"`.
    ///   - reason: The reason that the agent gave. Only `"failed"` keeps
    ///     it; each other status ignores it.
    /// - Returns: `nil` for a wire value that this client does not know.
    init?(wireValue: String, reason: String? = nil) {
        switch wireValue {
        case "connecting": self = .connecting
        case "connected": self = .connected
        case "failed": self = .failed(reason: reason)
        case "closed": self = .closed
        default: return nil
        }
    }
}

/// One MCP server of a session, as an observable item.
///
/// ``SessionModel/mcpServers`` holds one item for each server. The name is
/// the key of a server in a session, so it is also the identity of the item.
/// Only ``status`` changes.
@MainActor @Observable
public final class MCPServerItem: Identifiable {
    /// The name of the server.
    public nonisolated let name: String

    /// The transport of the server, or `nil` when the agent did not tell the
    /// transport.
    ///
    /// The agent sends a status update with no transport for a server that
    /// the client sent with a transport that the agent does not know. Such an
    /// update never removes a transport that the item already has.
    public let transport: MCPServerTransport?

    /// The source of the server.
    public let origin: MCPServerOrigin

    /// The configuration that the client sent, or `nil` for a server that the
    /// configuration of the agent gave or that has a transport that this
    /// schema revision does not know.
    public let server: MCPServer?

    /// The last connection status that the agent reported. A new item starts
    /// at ``MCPServerStatus/notReported``.
    public internal(set) var status: MCPServerStatus = .notReported

    /// The identity of the item: the name of the server.
    public nonisolated var id: String {
        name
    }

    /// Makes the item of a server that the client sent.
    ///
    /// A server with a transport that this schema revision does not know
    /// gives no item, because the model cannot tell its name or its
    /// transport.
    ///
    /// - Parameter server: The server of the request.
    init?(clientServer server: MCPServer) {
        switch server {
        case .http(let configuration):
            name = configuration.name
            transport = .http
        case .stdio(let configuration):
            name = configuration.name
            transport = .stdio
        case .unknown:
            return nil
        }
        origin = .client
        self.server = server
    }

    /// Makes the item of a server that the client does not have, from the
    /// status update of that server. The item has no configuration: the
    /// configuration of the agent gave the server, or the client sent it with
    /// a transport that this schema revision does not know. The item has no
    /// transport when the update has none.
    ///
    /// - Parameter update: The status update of the server.
    init(statusUpdate update: MCPServerStatusUpdate) {
        name = update.name
        transport = update.transport
        origin = update.origin
        server = nil
        status = update.status
    }
}
