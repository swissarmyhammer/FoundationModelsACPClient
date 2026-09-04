// `AgentSession` — the four steps `run`, `probe` and `doctor` all take before
// they diverge: connect over a transport, run `initialize`, open a session,
// and give back the session's update stream.
//
// The transport is injected, and this type starts nothing. The caller owns
// the agent process, so `RunCommand` hands over the agent's stdio while a
// unit test hands over one end of an `InMemoryTransport.pair()`. That is the
// whole reason the seam is unit-testable: no binary is started, and no test
// waits on a pipe.
//
// Two decisions in this file are not free choices.
//
// 1. The container is built with a `.zero` coalescing cadence. `cli-plan.md`
//    §8 wants each `agent_message_chunk` written to stdout as it arrives, and
//    the default cadence holds a chunk back for one display frame. That
//    default exists so a SwiftUI view does not thrash; a byte stream has no
//    such problem, and a delayed chunk is a delayed byte.
// 2. ``openSession()`` subscribes to the session's updates before it returns.
//    The wire package drops an update for a session with no active
//    subscriber, so a subscription taken after the prompt would lose every
//    chunk that arrived in between.
//
// `--cwd` is the **session's** working directory, and never this binary's.
// The value reaches the agent as `NewSessionRequest.cwd`, made absolute
// against the process working directory, and the process working directory
// itself never changes. `probe` uses the same option for the same reason: an
// agent reports what it supports for a workspace, and the workspace is the
// session's directory.
//
// One name to watch. `FoundationModelsACP` exports a `TerminalOutput` of its
// own — the ACP model of what an agent-owned terminal printed. Inside this
// target the local type wins the lookup, and the local type is the one this
// file means.

import Foundation
import FoundationModelsACP
import FoundationModelsACPClient

/// The connected, initialized agent one subcommand drives.
///
/// A value of this type owns a live connection. Build it over a transport the
/// caller owns, run ``initialize()``, open a session with ``openSession()``,
/// and run ``teardown()`` on every exit path.
@MainActor
struct AgentSession {
    /// The observable container the connection serves behind the declining
    /// wrapper.
    ///
    /// A caller reads the streamed answer off the session state this
    /// container holds, and reads ``SwiftUIACPClient/connectionState`` to
    /// learn that the agent went away.
    let container: SwiftUIACPClient

    /// The connection that drives the agent.
    let connection: ClientSideConnection

    /// The terminal layer that receives this seam's own diagnostics.
    private let output: TerminalOutput

    /// The `--cwd` value, or `nil` for the process working directory.
    ///
    /// The value stays as it was typed until ``openSession()`` resolves it,
    /// because resolving it can fail and ``openSession()`` is the member that
    /// can report a failure.
    private let requestedWorkingDirectory: String?

    /// Connects over `transport` and builds the seam around the connection.
    ///
    /// The initializer is `async` because connecting is the first of the four
    /// steps this type exists to share, and a value of this type is a live
    /// connection rather than a description of one. It starts no process: the
    /// caller owns whatever is on the far end of `transport`.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional transport to run over.
    ///   - terminal: The layer that receives every byte that is not the
    ///     answer text.
    ///   - cwd: The `--cwd` value, or `nil` for the process working
    ///     directory.
    init(
        over transport: any ACPTransport,
        terminal: TerminalOutput,
        cwd: String?
    ) async {
        let (container, connection) = await Self.connect(over: transport, terminal: terminal)
        self.container = container
        self.connection = connection
        output = terminal
        requestedWorkingDirectory = cwd
    }

    /// Connects one observable container over `transport`, behind the
    /// headless client.
    ///
    /// The connection serves a ``DecliningClient`` wrapping the container, so
    /// every request that waits on a person is refused at once and every
    /// notification still reaches the container.
    ///
    /// The connection's diagnostics go to ``TerminalOutput/event(_:)``, which
    /// writes to standard error behind `--verbose`. Nothing here can reach
    /// standard output, which §8 keeps for the answer text alone.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional transport to run over.
    ///   - terminal: The layer that receives the diagnostics and the
    ///     refusals.
    /// - Returns: The container and the connection that drives the agent.
    static func connect(
        over transport: any ACPTransport,
        terminal: TerminalOutput
    ) async -> (SwiftUIACPClient, ClientSideConnection) {
        // A zero cadence, because §8 writes each chunk as it arrives.
        let container = SwiftUIACPClient(coalescingCadence: .zero)
        let connection = await container.connect(over: transport, logger: terminal.logger) {
            served in
            DecliningClient(container: served, output: terminal)
        }
        return (container, connection)
    }

    /// Negotiates the protocol version and the capabilities with the agent.
    ///
    /// The request carries ``ACPClient/supportedProtocolVersion`` and
    /// ``ACPClient/advertisedCapabilities``, so this binary advertises exactly
    /// what the container implements and nothing more.
    ///
    /// - Returns: What the agent reported: its name, its version, its own
    ///   capabilities, and its authentication methods.
    /// - Throws: `RequestError` on a peer error, `ConnectionError` when the
    ///   agent went away, or `ProtocolVersionMismatchError` when the agent
    ///   answered with a version other than the one sent.
    func initialize() async throws -> InitializeResponse {
        try await connection.initialize(
            InitializeRequest(
                info: Implementation(
                    name: AcpClient.commandName,
                    version: AcpClientVersion.current
                ),
                protocolVersion: ACPClient.supportedProtocolVersion,
                capabilities: ACPClient.advertisedCapabilities
            )
        )
    }

    /// Opens one session and subscribes to its updates.
    ///
    /// The subscription is live before this call returns. The wire package
    /// drops an update for a session with no active subscriber, so a caller
    /// that subscribed after driving the turn would lose every chunk the
    /// agent sent in between.
    ///
    /// - Returns: The session the agent opened, and its update stream.
    /// - Throws: ``SessionWorkingDirectoryError`` when `--cwd` does not
    ///   resolve to an absolute path, `RequestError` on a peer error, or
    ///   `ConnectionError` when the agent went away.
    func openSession() async throws -> (SessionId, AsyncStream<SessionUpdate>) {
        let cwd = try Self.sessionWorkingDirectory(for: requestedWorkingDirectory)
        let response = try await connection.newSession(NewSessionRequest(cwd: cwd))
        return (response.sessionId, connection.updates(for: response.sessionId))
    }

    /// Asks the agent to close one session, and reports a refusal rather than
    /// raising it.
    ///
    /// `session/close` is optional on the wire, and an agent that does not
    /// implement it answers `methodNotFound`. The binary already has the
    /// answer it ran for by the time it closes, so a refusal here changes no
    /// exit code. It is written as one event line, which `--verbose` shows.
    ///
    /// - Parameter sessionId: The session to close.
    func closeSession(_ sessionId: SessionId) async {
        do {
            _ = try await connection.closeSession(CloseSessionRequest(sessionId: sessionId))
        } catch {
            output.event("session/close was not answered: \(error)")
        }
    }

    /// Closes the connection.
    ///
    /// The caller runs this on every exit path. Closing rejects every pending
    /// request, ends the transport, and flushes the container's buffered
    /// chunks, so nothing the agent already sent is left unwritten.
    func teardown() async {
        await connection.close()
    }

    /// Resolves the working directory the session runs in.
    ///
    /// An absent `--cwd` gives the process working directory, which is the
    /// default `cli-plan.md` §6.1 states. A relative `--cwd` is made absolute
    /// against that same directory. Neither path changes the process working
    /// directory: this binary stays where it was started, and only the
    /// session moves.
    ///
    /// - Parameter requested: The `--cwd` value, or `nil` for the process
    ///   working directory.
    /// - Returns: The absolute path to send as `NewSessionRequest.cwd`.
    /// - Throws: ``SessionWorkingDirectoryError`` when the resolved path is
    ///   not absolute.
    private static func sessionWorkingDirectory(for requested: String?) throws -> AbsolutePath {
        let processDirectory = FileManager.default.currentDirectoryPath
        guard let requested else {
            return try absolutePath(processDirectory)
        }
        let base = URL(fileURLWithPath: processDirectory, isDirectory: true)
        // `standardizedFileURL` removes "." and ".." without touching the
        // file system, so an agent gets a clean path and this binary reads no
        // directory to build it.
        let resolved = URL(fileURLWithPath: requested, relativeTo: base).standardizedFileURL
        return try absolutePath(resolved.path)
    }

    /// Wraps one resolved path in the wire's absolute-path type.
    ///
    /// - Parameter path: The path to wrap.
    /// - Returns: The wire value.
    /// - Throws: ``SessionWorkingDirectoryError`` when the path is not
    ///   absolute.
    private static func absolutePath(_ path: String) throws -> AbsolutePath {
        guard let absolute = AbsolutePath(rawValue: path) else {
            throw SessionWorkingDirectoryError(path: path)
        }
        return absolute
    }
}

/// The failure ``AgentSession/openSession()`` throws when the session's
/// working directory does not resolve to an absolute path.
///
/// `NewSessionRequest.cwd` is absolute by contract, so a path that is not
/// absolute cannot go on the wire at all. The message names the path, because
/// the value came from the command line and the person who typed it is the
/// one who can correct it.
struct SessionWorkingDirectoryError: Error, CustomStringConvertible {
    /// The path that did not resolve to an absolute path.
    let path: String

    /// A human-readable description of this error.
    var description: String {
        "The session working directory \"\(path)\" is not an absolute path."
    }
}
