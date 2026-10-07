// `AgentSession` — the four steps `run`, `probe` and `doctor` all take before
// they diverge: connect over a transport, run `initialize`, open a session,
// and give back the model of that session.
//
// The transport is injected, and this type starts nothing. The caller owns
// the agent process, so `RunCommand` hands over the agent's stdio while a
// unit test hands over one end of an `InMemoryTransport.pair()`. That is the
// whole reason the seam is unit-testable: no binary is started, and no test
// waits on a pipe.
//
// The seam drives the agent through one `ConnectionModel`. The model sends
// `initialize`, `session/new` and `session/close`, and it opens the client
// request span of each one, so this file opens no span of its own.
//
// Two decisions in this file are not free choices.
//
// 1. The connection model is built with a `.zero` coalescing cadence.
//    `cli-plan.md` §8 wants each `agent_message_chunk` written to stdout as it
//    arrives, and the default cadence holds a chunk back for one display
//    frame. That default exists so a SwiftUI view does not thrash; a byte
//    stream has no such problem, and a delayed chunk is a delayed byte.
// 2. ``openSession()`` gives the `SessionModel` that the connection model
//    opened. That model subscribes to the updates of its session before
//    `newSession` returns. The wire package keeps the updates of a session
//    with no subscriber in a buffer of limited size, and a full buffer
//    discards them, so a subscription taken after a long prompt could lose
//    chunks.
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
    /// The observable model of the connection, served behind the declining
    /// wrapper.
    ///
    /// A caller reads the open session models off this model, and reads
    /// ``ConnectionModel/state`` to learn that the agent went away.
    let model: ConnectionModel

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

    /// The text that starts the event line of a `session/close` that got no
    /// answer of the agent's own.
    private static let unansweredCloseLine = "session/close was not answered"

    /// The text that starts the event line of a `session/close` the agent
    /// answered with an error, or that failed on the way.
    private static let failedCloseLine = "session/close failed"

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
    ///   - clock: The clock that schedules the coalesced flushes of the
    ///     session models. A test injects a manual clock, so it reads no wall
    ///     clock.
    init(
        over transport: any ACPTransport,
        terminal: TerminalOutput,
        cwd: String?,
        processWorkingDirectory: @escaping () -> String = { FileManager.default.currentDirectoryPath },
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        let (model, connection) = await Self.connect(
            over: transport,
            terminal: terminal,
            clock: clock
        )
        self.model = model
        self.connection = connection
        output = terminal
        requestedWorkingDirectory = cwd
        self.processWorkingDirectory = processWorkingDirectory
    }

    /// Connects one connection model over `transport`, behind the headless
    /// client.
    ///
    /// The connection serves a ``DecliningClient`` in front of the router of
    /// the model, so every request that waits on a person is refused at once
    /// and every notification still reaches the models.
    ///
    /// The connection's diagnostics go to ``TerminalOutput/event(_:)``, which
    /// writes to standard error behind `--verbose`. Nothing here can reach
    /// standard output, which §8 keeps for the answer text alone.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional transport to run over.
    ///   - terminal: The layer that receives the diagnostics and the
    ///     refusals.
    ///   - clock: The clock that schedules the coalesced flushes of the
    ///     session models. A test injects a manual clock, so it reads no wall
    ///     clock.
    /// - Returns: The connection model and the connection that drives the
    ///   agent.
    static func connect(
        over transport: any ACPTransport,
        terminal: TerminalOutput,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> (ConnectionModel, ClientSideConnection) {
        // A zero cadence, because §8 writes each chunk as it arrives.
        let model = ConnectionModel(coalescingCadence: .zero, clock: clock)
        let connection = await model.connect(over: transport, logger: terminal.logger) { router in
            DecliningClient(inner: router, output: terminal)
        }
        return (model, connection)
    }

    /// Negotiates the protocol version and the capabilities with the agent.
    ///
    /// The request carries ``ACPClient/supportedProtocolVersion`` and
    /// ``ACPClient/advertisedCapabilities``, so this binary advertises exactly
    /// what the models implement and nothing more.
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
        let response = try await model.initialize(
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

    /// Opens one session, and gives its model.
    ///
    /// The model is subscribed to the updates of the session before this call
    /// returns, so an update the agent sends at once is in the model. Decision
    /// 2 at the head of this file states why.
    ///
    /// The session that opens is a session event of §8, and the line carries
    /// the working directory beside the id, so a person reads what the agent
    /// was told. `--cwd` goes to the agent as typed: an agent that refuses
    /// the path answers a `RequestError`, which is the protocol-failure row
    /// of §9.
    ///
    /// - Returns: The model of the session the agent opened.
    /// - Throws: ``ProcessWorkingDirectoryError`` when `--cwd` is absent and
    ///   this process has no working directory, `RequestError` on a peer
    ///   error, or `ConnectionError` when the agent went away.
    func openSession() async throws -> SessionModel {
        let cwd = AbsolutePath(rawValue: try workingDirectoryToSend())
        let session = try await model.newSession(NewSessionRequest(cwd: cwd))
        output.event(
            "session/new opened \(session.sessionId.rawValue) in \(cwd.rawValue)"
        )
        return session
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
    /// visible on ``ConnectionModel/state``. What happens here is one event
    /// line, which `--verbose` shows.
    ///
    /// The two lines are not one line. `session/close` is optional on the
    /// wire. An agent that does not advertise the session baseline has no
    /// `session/close`, so the connection model sends none; an agent that
    /// advertises it and does not implement it answers `methodNotFound`. In
    /// both cases the agent gave the call no answer of its own, and the line
    /// says so. Every other error is a different fact — an `invalidParams` or
    /// `internalError` answer IS an answer, a `ConnectionError` means the
    /// agent went away, and a `CancellationError` means this binary is on its
    /// way out — so each of those is reported as a failed call that names the
    /// error.
    ///
    /// - Parameter session: The model of the session to close.
    func closeSession(_ session: SessionModel) async {
        do {
            try await model.close(session)
        } catch where Self.isUnanswered(error) {
            output.event("\(Self.unansweredCloseLine): \(error)")
        } catch {
            output.event("\(Self.failedCloseLine): \(error)")
        }
    }

    /// Tells whether a `session/close` error means the agent gave the call no
    /// answer of its own.
    ///
    /// - Parameter error: The error the close threw.
    /// - Returns: `true` for a `methodNotFound` answer, and for the connection
    ///   model's refusal to send a close the agent does not advertise.
    private static func isUnanswered(_ error: any Error) -> Bool {
        switch error {
        case let refusal as RequestError:
            refusal.code == .methodNotFound
        case let unsent as ConnectionModelError:
            switch unsent {
            case .unsupported:
                true
            case .terminalAuthFailed:
                false
            }
        default:
            false
        }
    }

    /// Closes the connection.
    ///
    /// The caller runs this on every exit path. Closing rejects every pending
    /// request, ends the transport, and closes each open session model, which
    /// folds its buffered chunks, so nothing the agent already sent is left
    /// unapplied.
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
