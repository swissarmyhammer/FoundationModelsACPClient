import FoundationModelsACP
import Observation

/// The built-in extension that keeps the MCP servers of a session and the
/// status that the agent reports for each one.
///
/// The request of a `session/new` or a `session/resume` seeds the list in
/// ``didStartSession(state:mcpServers:)``. The extension takes each
/// `_mcp_server_status` update, so the update never goes to the engine and
/// adds no transcript entry. ``SessionModel/mcpServers`` reads the list.
struct MCPServerStatusExtension: ClientModelExtension {
    /// The session state of the extension: the MCP servers of one session.
    @MainActor @Observable
    final class SessionState {
        /// The MCP servers of the session, in the order of the request, and
        /// then in the order of the first status update of each other
        /// server.
        var servers: [MCPServerItem] = []

        /// Replaces the list with the servers that the client sends in a
        /// `session/new` or `session/resume` request.
        ///
        /// Each HTTP or stdio server gives one ``MCPServerOrigin/client``
        /// item, in request order, with the status
        /// ``MCPServerStatus/notReported``. A server with a transport that
        /// this schema revision does not know gives no item.
        ///
        /// - Parameter clientServers: The `mcpServers` field of the request.
        func replaceServers(with clientServers: [MCPServer]) {
            servers = clientServers.compactMap(MCPServerItem.init(clientServer:))
        }

        /// Applies one `_mcp_server_status` update of the agent to the list.
        ///
        /// The update replaces the status of the item with its name, and no
        /// other item changes. The item keeps its transport, also when the
        /// update has no transport. When no item has that name, the update
        /// appends a new item with the name, the transport, the origin and
        /// the status of the update, and with no configuration: the client
        /// does not have the configuration of that server.
        ///
        /// - Parameter update: The decoded status update.
        func apply(_ update: MCPServerStatusUpdate) {
            guard let item = servers.first(where: { $0.name == update.name }) else {
                servers.append(MCPServerItem(statusUpdate: update))
                return
            }
            item.status = update.status
        }
    }

    @MainActor func makeConnectionState() -> EmptyExtensionConnectionState {
        EmptyExtensionConnectionState()
    }

    @MainActor func makeSessionState(for sessionId: SessionId) -> SessionState {
        SessionState()
    }

    func registerHandlers(
        into handlers: inout ClientModelExtensionHandlers,
        context: ClientModelExtensionContext<Self>
    ) {}

    /// Takes each `_mcp_server_status` update. A valid one changes the list,
    /// and an update that ``MCPServerStatusUpdate`` ignores changes nothing.
    ///
    /// - Parameters:
    ///   - update: The session update.
    ///   - state: The session state.
    /// - Returns: `true` for each `_mcp_server_status` update.
    @MainActor func apply(_ update: SessionUpdate, to state: SessionState) -> Bool {
        guard MCPServerStatusUpdate.isStatusUpdate(update) else { return false }
        if let status = MCPServerStatusUpdate.decode(update) {
            state.apply(status)
        }
        return true
    }

    /// Replaces the list with the servers of the request, so a status update
    /// that the agent sends after the request finds its item.
    ///
    /// - Parameters:
    ///   - state: The session state.
    ///   - request: The request that went out.
    @MainActor func didStartSession(state: SessionState, mcpServers request: any MCPServerListRequest) {
        state.replaceServers(with: request.mcpServers ?? [])
    }
}
