import FoundationModelsACP

/// Runs an ACP agent in the process of the host, and connects a
/// `ConnectionModel` to it.
///
/// The helper pairs `InMemoryTransport.pair()`. It gives one end to an
/// `AgentSideConnection` that serves the `Agent` of the host, and connects a
/// new `ConnectionModel` over the other end. The two sides speak the real ACP
/// wire, so a view sees the same model that a subprocess agent gives.
///
/// The helper returns the model and keeps no state of its own. A view binds
/// to the model directly: the connection state is `ConnectionModel.state`,
/// and each open session is a `SessionModel` of the model. The host gives the
/// agent. With FoundationModelsACPAgent, the host uses its public
/// `ComposedAgent` in four steps:
///
/// ```swift
/// // 1. Compose the agent one time, before the connection opens.
/// let composed = try await ComposedAgent.compose(
///     name: try DotfolderName("my-host"), workingDirectory: projectDirectory,
///     home: .makeCustom(synced: syncedFolder, local: localFolder))
/// // 2. Bind the agent to the agent side of the connection.
/// let model = await InProcessAgent.makeConnection { connection in
///     composed.agent(boundTo: connection)
/// }
/// // 3. Initialize the connection.
/// _ = try await model.initialize(InitializeRequest(
///     info: Implementation(name: "my-host", version: "1.0.0"),
///     protocolVersion: ACPClient.supportedProtocolVersion,
///     capabilities: ACPClient.advertisedCapabilities))
/// // 4. Close the connection. Then let the agent close its sessions.
/// await model.disconnect()
/// await composed.waitForConnectionTeardown()
/// ```
///
/// The host closes the connection with `ConnectionModel.disconnect()`. The
/// model then stops the read of its end of the pair, and
/// `InMemoryTransport.pair()` ends the input of the agent side. The agent
/// side reads the end of its input and stops, as an agent process that
/// `disconnect()` ends.
///
/// The agent side can also stop first, when the agent closes its connection
/// (`AgentSideConnection.close()`). Then the helper closes the two ends of
/// the pair, as an agent process that exits, and `ConnectionModel.state`
/// becomes `.disconnected`.
@MainActor
public enum InProcessAgent {
    /// Starts an agent in this process and connects a new model to it.
    ///
    /// The helper keeps the agent side of the connection until it closes,
    /// because an agent such as `RoutedACPAgent` keeps its connection weakly.
    /// A task waits for the close, closes the two ends of the pair, and then
    /// ends. The task is not structured, because it must live after this call
    /// returns. It ends when the agent side closes, and each close of the
    /// connection closes the agent side.
    ///
    /// The returned model is connected and not initialized. Send `initialize`
    /// with ``ConnectionModel/initialize(_:)``, for example with an
    /// `InitializeRequest` that has ``ACPClient/supportedProtocolVersion`` and
    /// ``ACPClient/advertisedCapabilities``.
    ///
    /// - Parameter makeAgent: Makes the agent from the agent side of the
    ///   connection. The agent sends its session updates through that
    ///   connection.
    /// - Returns: The connection model of the client side.
    public static func makeConnection(
        serving makeAgent: @Sendable (AgentSideConnection) -> any Agent
    ) async -> ConnectionModel {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await AgentSideConnection(stream: agentEnd, makeAgent)
        Task {
            _ = await agentConnection.closed
            agentEnd.close()
            clientEnd.close()
        }
        let model = ConnectionModel()
        _ = await model.connect(over: clientEnd)
        return model
    }
}
