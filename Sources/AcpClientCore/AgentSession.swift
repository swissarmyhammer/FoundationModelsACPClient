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
// The value reaches the agent as `NewSessionRequest.cwd` exactly as typed:
// this binary does not resolve it, does not normalise it, and does not check
// it. The agent owns the file system the session runs in, and that agent can
// stand on another machine, so the agent is the only judge of the path. The
// process working directory itself never changes. `probe` uses the same
// option for the same reason: an agent reports what it supports for a
// workspace, and the workspace is the session's directory.
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

    /// The `--cwd` value as typed, or `nil` for the process working directory.
    ///
    /// The value goes to the agent with no change. `cli-plan.md` §6.1 gives
    /// the agent the whole judgement of it, so this seam holds no opinion.
    private let requestedWorkingDirectory: String?

    /// Reads the working directory of this process.
    ///
    /// It is injected for the one failure this seam reports of its own: a
    /// process whose working directory was deleted reads an empty string
    /// here. A test injects that reading, because no test may delete the
    /// directory the whole test process runs in.
    private let processWorkingDirectory: () -> String

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
    ///   - processWorkingDirectory: What this seam reads as the working
    ///     directory of this process. The default reads the real one.
    ///   - clock: The clock that schedules the container's coalesced flushes.
    ///     A test injects a manual clock, so it reads no wall clock.
    init(
        over transport: any ACPTransport,
        terminal: TerminalOutput,
        cwd: String?,
        processWorkingDirectory: @escaping () -> String = { FileManager.default.currentDirectoryPath },
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        let (container, connection) = await Self.connect(
            over: transport,
            terminal: terminal,
            clock: clock
        )
        self.container = container
        self.connection = connection
        output = terminal
        requestedWorkingDirectory = cwd
        self.processWorkingDirectory = processWorkingDirectory
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
    ///   - clock: The clock that schedules the container's coalesced flushes.
    ///     A test injects a manual clock, so it reads no wall clock.
    /// - Returns: The container and the connection that drives the agent.
    static func connect(
        over transport: any ACPTransport,
        terminal: TerminalOutput,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> (SwiftUIACPClient, ClientSideConnection) {
        // A zero cadence, because §8 writes each chunk as it arrives.
        let container = SwiftUIACPClient(coalescingCadence: .zero, clock: clock)
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
    /// The answer is the first session event `cli-plan.md` §8 gives
    /// `--verbose`: it says who is on the far end of the transport, and which
    /// protocol version that agent answered with. §8 keeps standard output for
    /// the answer text alone, so `--verbose` is the only place a person can
    /// read either fact.
    ///
    /// - Returns: What the agent reported: its name, its version, its own
    ///   capabilities, and its authentication methods.
    /// - Throws: `RequestError` on a peer error, `ConnectionError` when the
    ///   agent went away, or `ProtocolVersionMismatchError` when the agent
    ///   answered with a version other than the one sent.
    func initialize() async throws -> InitializeResponse {
        let response = try await connection.initialize(
            InitializeRequest(
                info: Implementation(
                    name: AcpClient.commandName,
                    version: AcpClientVersion.current
                ),
                protocolVersion: ACPClient.supportedProtocolVersion,
                capabilities: ACPClient.advertisedCapabilities
            )
        )
        output.event(
            """
            initialize answered by \(response.info.name) \(response.info.version), \
            protocol version \(response.protocolVersion.rawValue)
            """
        )
        return response
    }

    /// Opens one session and subscribes to its updates.
    ///
    /// The subscription is live before this call returns. The wire package
    /// drops an update for a session with no active subscriber, so a caller
    /// that subscribed after driving the turn would lose every chunk the
    /// agent sent in between.
    ///
    /// The session that opens is a session event of §8, and the line carries
    /// the working directory beside the id, so a person reads what the agent
    /// was told. `--cwd` goes to the agent as typed: an agent that refuses
    /// the path answers a `RequestError`, which is the protocol-failure row
    /// of §9.
    ///
    /// - Returns: The session the agent opened, and its update stream.
    /// - Throws: ``ProcessWorkingDirectoryError`` when `--cwd` is absent and
    ///   this process has no working directory, `RequestError` on a peer
    ///   error, or `ConnectionError` when the agent went away.
    func openSession() async throws -> (SessionId, AsyncStream<SessionUpdate>) {
        let cwd = AbsolutePath(rawValue: try workingDirectoryToSend())
        let response = try await connection.newSession(NewSessionRequest(cwd: cwd))
        output.event(
            "session/new opened \(response.sessionId.rawValue) in \(cwd.rawValue)"
        )
        return (response.sessionId, connection.updates(for: response.sessionId))
    }

    /// Returns the `cwd` to send: `--cwd` as typed, or the working directory
    /// of this process when `--cwd` is absent.
    ///
    /// - Returns: The path, exactly as it goes on the wire.
    /// - Throws: ``ProcessWorkingDirectoryError`` when `--cwd` is absent and
    ///   this process has no working directory.
    private func workingDirectoryToSend() throws -> String {
        if let requestedWorkingDirectory {
            return requestedWorkingDirectory
        }
        let processDirectory = processWorkingDirectory()
        guard !processDirectory.isEmpty else {
            throw ProcessWorkingDirectoryError()
        }
        return processDirectory
    }

    /// Asks the agent to close one session, and reports what came back rather
    /// than raising it.
    ///
    /// The binary already has the answer it ran for by the time it closes, so
    /// nothing that happens here changes an exit code, and a dead agent stays
    /// visible on ``SwiftUIACPClient/connectionState``. What happens here is
    /// one event line, which `--verbose` shows.
    ///
    /// The two lines are not one line. `session/close` is optional on the
    /// wire, and an agent that does not implement it answers `methodNotFound`:
    /// that agent gave the call no answer of its own, and the line says so.
    /// Every other error is a different fact — an `invalidParams` or
    /// `internalError` answer IS an answer, a `ConnectionError` means the
    /// agent went away, and a `CancellationError` means this binary is on its
    /// way out — so each of those is reported as a failed call that names the
    /// error.
    ///
    /// - Parameter sessionId: The session to close.
    func closeSession(_ sessionId: SessionId) async {
        do {
            _ = try await connection.closeSession(CloseSessionRequest(sessionId: sessionId))
        } catch let error as RequestError where error.code == .methodNotFound {
            output.event("session/close was not answered: \(error)")
        } catch {
            output.event("session/close failed: \(error)")
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
}

/// The failure ``AgentSession/openSession()`` throws when `--cwd` is absent
/// and this process has no working directory.
///
/// `FileManager.default.currentDirectoryPath` answers an empty string when
/// the directory the process started in was deleted. An empty string is no
/// path, so it cannot stand for the session's working directory, and it is
/// not a mistake on the command line: the person gave no `--cwd` at all. The
/// message names the two repairs, because the person who reads it is the one
/// who can make either.
struct ProcessWorkingDirectoryError: Error, CustomStringConvertible {
    /// A human-readable description of this error.
    var description: String {
        """
        This process has no working directory: the directory it started in \
        is gone. Give --cwd, or start from a directory that exists.
        """
    }
}
