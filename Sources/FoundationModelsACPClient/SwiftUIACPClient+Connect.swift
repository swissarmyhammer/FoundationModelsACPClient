// M6: the host-facing attach point. One call wires this observable client
// over any `ACPTransport` — the in-process `InMemoryTransport.pair()` end,
// or the stdio transport an `AgentProcess` vends — and keeps
// `connectionState` true to the transport's life. The wire package's
// `ClientSideConnection.closed` gives the close of the connection one time,
// for each cause, so this file waits for it and sets the state.

import FoundationModelsACP

extension SwiftUIACPClient {
    /// Connects this client over `transport` and returns the connection
    /// that drives the agent.
    ///
    /// ``connectionState`` becomes ``ConnectionState/connected`` at once.
    /// It becomes ``ConnectionState/disconnected`` when the connection
    /// closes, for any cause: the agent died (its byte stream reached EOF or
    /// failed), or the host closed the returned connection. A dead agent
    /// therefore surfaces as observable state, never as a hang — the wire
    /// package already rejects each pending request with
    /// `ConnectionError.closed` on disconnect.
    ///
    /// One connection is active per client at a time. After a disconnect,
    /// the host may call this again with a fresh transport; the session
    /// state this client already holds stays as it is, and the host reloads
    /// it over the new connection itself. This package never reconnects on
    /// its own — see ``AgentProcess`` for the no-automatic-respawn policy.
    ///
    /// The connection serves this client itself. A host that must put its
    /// own `Client` in front of this container calls
    /// ``connect(over:logger:client:)`` instead.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional transport to run over.
    ///   - logger: Diagnostic sink; never stdout.
    /// - Returns: The client-side connection, ready to drive the agent.
    public func connect(
        over transport: any ACPTransport,
        logger: ACPLogger = .disabled
    ) async -> ClientSideConnection {
        await connect(over: transport, logger: logger) { $0 }
    }

    /// Connects this client over `transport`, serving the `Client` that
    /// `client` returns, and returns the connection that drives the agent.
    ///
    /// This is the seam for a host that must answer the agent itself. A
    /// headless host — a command-line tool with nobody at the keyboard —
    /// wraps this container in a `Client` that declines every permission
    /// request and every elicitation, because no person is there to decide
    /// them, and forwards everything else.
    ///
    /// `client` receives this container and returns the `Client` the
    /// connection serves. It runs one time for each call of this method, on
    /// the main actor, before the connection starts to serve.
    ///
    /// A wrapper must forward ``SwiftUIACPClient/sessionUpdate(_:)`` and
    /// ``SwiftUIACPClient/elicitationComplete(_:)`` to the container it
    /// receives. The connection delivers each of those one time, to the
    /// `Client` it serves and to nothing else, so a wrapper that swallows
    /// either one leaves the container's observable state stale, and no
    /// later call repairs it.
    ///
    /// ``connectionState`` follows the connection exactly as it does on
    /// ``connect(over:logger:)``: a wrapper changes which `Client` the
    /// agent reaches, and changes nothing about the connection's life.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional transport to run over.
    ///   - logger: Diagnostic sink; never stdout.
    ///   - client: Builds the `Client` the connection serves, from this
    ///     container.
    /// - Returns: The client-side connection, ready to drive the agent.
    public func connect(
        over transport: any ACPTransport,
        logger: ACPLogger = .disabled,
        client: @escaping @Sendable @MainActor (SwiftUIACPClient) -> any Client
    ) async -> ClientSideConnection {
        connectionState = .connected
        // The wire package's factory is not main-actor isolated, so the
        // served client is built here, on the main actor, and handed over
        // ready-made. That is also what holds `client` to one call.
        let served = client(self)
        let connection = await ClientSideConnection(stream: transport, logger: logger) { _ in served }
        // This container knows one closed state: each close reason,
        // a failure too, is a disconnect here.
        connection.onClose { [weak self] _ in
            self?.connectionState = .disconnected
        }
        return connection
    }
}
