import FoundationModelsACP
import Observation

/// The transport of an MCP server.
public enum MCPServerTransport: String, Hashable, Sendable {
    /// The agent starts the server as a process and talks to it on its
    /// standard input and output. The wire value is `"stdio"`.
    case stdio

    /// The agent talks to the server over HTTP. The wire value is `"http"`.
    case http
}

/// The source of an MCP server of a session.
public enum MCPServerOrigin: Hashable, Sendable {
    /// The client sent the server in its `session/new` or `session/resume`
    /// request.
    case client

    /// The configuration of the agent gave the server.
    case config
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

    /// The transport of the server.
    public let transport: MCPServerTransport

    /// The source of the server.
    public let origin: MCPServerOrigin

    /// The configuration that the client sent, or `nil` for a server that the
    /// configuration of the agent gave.
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
}
