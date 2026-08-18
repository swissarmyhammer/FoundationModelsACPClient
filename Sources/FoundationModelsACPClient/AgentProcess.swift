// `AgentProcess` — this package owns the lifecycle of the external agent it
// spawns (plan.md, "Transports, and who owns the agent process"). It mirrors
// the family discipline that `FoundationModelsShelltool` and
// `FoundationModelsMCP` (`StdioServerProcess`) already implement: spawn in
// the child's own process group, so the agent's own children die with it;
// register the pid in a `ProcessRegistry`; group-kill *and* reap on every
// teardown path; and backstop everything with the same `atexit` sweep and
// the same honestly-stated limitation — a normal exit only, never `SIGKILL`
// or a crash. Those sibling types are internal to their own packages, and
// this package depends on the ACP wire only, so this file holds this
// package's own copy of the pattern.
//
// Spawning goes through raw `posix_spawn` rather than `Foundation.Process`,
// for the sibling's own reason: `Process` gives no public way to put a child
// in its own process group before it execs, and
// `POSIX_SPAWN_SETPGROUP`/`posix_spawnattr_setpgroup(0)` sets the group
// atomically as a part of the spawn.
//
// Three independent teardown triggers all funnel through the same idempotent
// `AgentProcessState.terminateCurrent()`, so a call from any of them, in any
// order, any number of times, is safe:
//
//   1. Explicit `shutdown()` — the host tears the agent down on purpose.
//   2. Transport teardown — the consumer of `transport.bytes` stops (the
//      host closed the `ClientSideConnection`, or dropped the transport),
//      or the read loop reaches EOF because the agent died on its own. The
//      EOF path is what reaps an agent that died: `killpg` of the dead
//      group is a harmless `ESRCH`, and `waitpid` collects the zombie.
//   3. Owner teardown — `AgentProcessState.deinit`. Once nothing retains
//      the state, ARC runs the same idempotent teardown.
//
// **Respawn policy (decided): no automatic respawn, ever.** An agent that
// died surfaces as `.disconnected` observable connection state, never as a
// silent restart into an empty session. A host that wants a fresh agent
// constructs a new `AgentProcess`, connects again, and reloads its sessions
// itself. This value spawns exactly one child, in `init`, and never a
// second one.

import Darwin
import Foundation
import FoundationModelsACP
import Synchronization

/// A failure while constructing an ``AgentProcess`` or while speaking to
/// its agent.
public enum AgentProcessError: Error, Equatable, CustomStringConvertible {
    /// ``AgentProcess/init(command:arguments:)`` got a `command` that is
    /// not an absolute path.
    ///
    /// This package requires an absolute path rather than a `PATH` lookup,
    /// for the family's own reason: a relative lookup would have to select
    /// *which* `PATH` applies. A caller that only has a bare command name
    /// must resolve it to an absolute path first.
    case commandNotAbsolute(String)

    /// Creating the stdin or stdout pipe failed; carries the C `errno`.
    case pipeCreationFailed(errno: Int32)

    /// `posix_spawn` itself failed; carries the `command` path and the
    /// error number `posix_spawn` returned directly.
    case spawnFailed(command: String, errno: Int32)

    /// A write to the agent's stdin failed; carries the C `errno`. After
    /// the agent died, this is `EPIPE` rather than a `SIGPIPE` that would
    /// take the whole host process down — see the spawn path for the
    /// `F_SETNOSIGPIPE` that makes it so.
    case writeFailed(errno: Int32)

    /// A read from the agent's stdout failed; carries the C `errno`.
    case readFailed(errno: Int32)

    /// A write was attempted after the agent process was torn down.
    case agentUnavailable

    /// A human-readable description of this error.
    public var description: String {
        switch self {
        case .commandNotAbsolute(let command):
            return "AgentProcess requires an absolute path to the agent executable; got \"\(command)\"."
        case .pipeCreationFailed(let errno):
            return "AgentProcess failed to create a pipe: \(String(cString: strerror(errno)))"
        case .spawnFailed(let command, let errno):
            return "AgentProcess failed to spawn \"\(command)\": \(String(cString: strerror(errno)))"
        case .writeFailed(let errno):
            return "AgentProcess failed to write to the agent's stdin: \(String(cString: strerror(errno)))"
        case .readFailed(let errno):
            return "AgentProcess failed to read the agent's stdout: \(String(cString: strerror(errno)))"
        case .agentUnavailable:
            return "AgentProcess has already torn its agent down; no write is possible."
        }
    }
}

/// Spawns an external ACP agent binary in its own process group and vends an
/// `ACPTransport` wired to its stdio.
///
/// The child's stdout becomes the transport's `bytes`, and `write(_:)`
/// feeds the child's stdin. The child's stderr stays inherited from this
/// process, so the agent's diagnostics never pollute the wire.
///
/// The child is group-killed and reaped on ``shutdown()``, on transport
/// teardown (connection close, or the stream dropped), on the agent's own
/// death (the EOF path reaps the zombie), and on owner teardown — see the
/// file header for the full list, and for the honest limitation of the
/// `atexit` backstop under `SIGKILL` or a crash.
///
/// **Respawn policy: never automatic.** An agent death surfaces as
/// `.disconnected` connection state on the observing client. This value
/// never restarts a died agent — a silent restart would put an empty
/// session behind live-looking state. Construct a new `AgentProcess` and
/// connect again instead.
public struct AgentProcess: Sendable {
    /// The absolute path of the agent executable.
    public let command: String

    /// The arguments given to ``command`` at the spawn.
    public let arguments: [String]

    /// The transport wired to the agent's stdio. Hand it to
    /// ``SwiftUIACPClient/connect(over:logger:)``.
    public let transport: any ACPTransport

    /// The shared, class-backed process bookkeeping every copy of this
    /// value refers to.
    private let state: AgentProcessState

    /// Spawns the agent process, in its own process group, and wires its
    /// stdio to ``transport``.
    ///
    /// The child inherits this process's environment and its stderr.
    ///
    /// - Parameters:
    ///   - command: The absolute path of the agent executable.
    ///   - arguments: The arguments to give to the agent.
    /// - Throws: ``AgentProcessError/commandNotAbsolute(_:)`` for a
    ///   relative `command`, ``AgentProcessError/pipeCreationFailed(errno:)``
    ///   when a pipe cannot be made, or
    ///   ``AgentProcessError/spawnFailed(command:errno:)`` when
    ///   `posix_spawn` itself fails.
    public init(command: String, arguments: [String] = []) throws {
        guard command.hasPrefix("/") else {
            throw AgentProcessError.commandNotAbsolute(command)
        }
        self.command = command
        self.arguments = arguments

        let spawned = try Self.spawn(command: command, arguments: arguments)
        let state = AgentProcessState(registry: .global)
        state.record(pid: spawned.pid, stdinWriteDescriptor: spawned.stdinWriteDescriptor)
        self.state = state

        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        // Tear down when the consumer stops the stream (connection close or
        // cancellation), so a stalled agent never outlives its driver.
        continuation.onTermination = { _ in state.terminateCurrent() }
        Self.startReader(
            descriptor: spawned.stdoutReadDescriptor, state: state, continuation: continuation
        )
        self.transport = AgentStdioTransport(bytes: stream, state: state)
    }

    /// The pid of the live agent, or `nil` after teardown.
    ///
    /// Tests assert teardown by pid, not by inference; a host never needs
    /// this to use ``shutdown()`` correctly.
    public var processIdentifier: pid_t? { state.pid }

    /// Group-kills and reaps the agent. Idempotent; a no-op when the agent
    /// is already torn down.
    public func shutdown() {
        state.terminateCurrent()
    }

    // MARK: - Spawning

    /// One freshly spawned agent: its pid and this process's ends of the
    /// two stdio pipes.
    private struct Spawned {
        /// The agent's pid, equal to its process-group id.
        let pid: pid_t
        /// The write end that feeds the agent's stdin.
        let stdinWriteDescriptor: Int32
        /// The read end that carries the agent's stdout.
        let stdoutReadDescriptor: Int32
    }

    /// The child's stdin file descriptor number, the `dup2` target.
    private static let childStdinDescriptor: Int32 = 0

    /// The child's stdout file descriptor number, the `dup2` target.
    private static let childStdoutDescriptor: Int32 = 1

    /// Spawns `command` in its own process group, with its stdin and stdout
    /// piped to this process.
    ///
    /// - Parameters:
    ///   - command: The absolute path of the executable.
    ///   - arguments: The arguments to give it.
    /// - Returns: The spawned pid and this process's pipe ends.
    /// - Throws: ``AgentProcessError/pipeCreationFailed(errno:)`` or
    ///   ``AgentProcessError/spawnFailed(command:errno:)``.
    private static func spawn(command: String, arguments: [String]) throws -> Spawned {
        let (stdinRead, stdinWrite) = try createPipe()
        // A write to a dead child's stdin raises `SIGPIPE` by default, and
        // that signal terminates the whole host process. `F_SETNOSIGPIPE`
        // makes such a write fail with `EPIPE` instead, which surfaces as
        // an ordinary thrown error and a graceful disconnect. Scoped to
        // this one descriptor, so the host's own pipes keep their own
        // `SIGPIPE` disposition.
        _ = fcntl(stdinWrite, F_SETNOSIGPIPE, 1)

        let (stdoutRead, stdoutWrite): (Int32, Int32)
        do {
            (stdoutRead, stdoutWrite) = try createPipe()
        } catch {
            close(stdinRead)
            close(stdinWrite)
            throw error
        }

        let pid: pid_t
        do {
            pid = try spawnChild(
                command: command, arguments: arguments,
                childStdin: stdinRead, childStdout: stdoutWrite,
                parentSideFdsToClose: [stdinWrite, stdoutRead]
            )
        } catch {
            // The spawn failed before any child inherited these
            // descriptors, so all four are still this process's to close.
            close(stdinRead)
            close(stdinWrite)
            close(stdoutRead)
            close(stdoutWrite)
            throw error
        }

        // `posix_spawn_file_actions` closes descriptors inside the child
        // only, never in this process, so the child's ends must be closed
        // here or each spawn leaks two descriptors.
        close(stdinRead)
        close(stdoutWrite)

        return Spawned(pid: pid, stdinWriteDescriptor: stdinWrite, stdoutReadDescriptor: stdoutRead)
    }

    /// Creates a pipe and returns its read and write ends.
    ///
    /// - Returns: The `(readEnd, writeEnd)` pair from `pipe(2)`.
    /// - Throws: ``AgentProcessError/pipeCreationFailed(errno:)``.
    private static func createPipe() throws -> (readEnd: Int32, writeEnd: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw AgentProcessError.pipeCreationFailed(errno: errno)
        }
        return (descriptors[0], descriptors[1])
    }

    /// Performs the `posix_spawn` call: wires `childStdin` and `childStdout`
    /// onto the child's descriptors 0 and 1, and puts the child in its own
    /// process group.
    ///
    /// - Parameters:
    ///   - command: The absolute path of the executable.
    ///   - arguments: The arguments to give it.
    ///   - childStdin: The read end of the stdin pipe, the child's 0.
    ///   - childStdout: The write end of the stdout pipe, the child's 1.
    ///   - parentSideFdsToClose: This process's own pipe ends, closed on
    ///     the child side only; the caller still closes its own copies.
    /// - Returns: The spawned pid.
    /// - Throws: ``AgentProcessError/spawnFailed(command:errno:)``.
    private static func spawnChild(
        command: String, arguments: [String],
        childStdin: Int32, childStdout: Int32, parentSideFdsToClose: [Int32]
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, childStdin, childStdinDescriptor)
        posix_spawn_file_actions_adddup2(&fileActions, childStdout, childStdoutDescriptor)
        // The child inherited copies of all four pipe descriptors across
        // the fork; only the dup2 targets above must stay live in it.
        for descriptor in [childStdin, childStdout] + parentSideFdsToClose {
            posix_spawn_file_actions_addclose(&fileActions, descriptor)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([command] + arguments).map { strdup($0) } + [nil]
        defer { freePointers(argv) }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, command, &fileActions, &attributes, argv, environ)
        guard spawnResult == 0 else {
            throw AgentProcessError.spawnFailed(command: command, errno: spawnResult)
        }
        return pid
    }

    /// Frees each non-nil `strdup`'d C string in `pointers`.
    ///
    /// - Parameter pointers: The pointers to free; the `nil` terminator is
    ///   skipped.
    private static func freePointers(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for case let pointer? in pointers {
            free(pointer)
        }
    }

    // MARK: - Reading

    /// The read buffer size, large enough to drain a typical pipe burst in
    /// one syscall — the same size the wire package's own reader uses.
    private static let readBufferSize = 64 * 1024

    /// Starts the reader thread for the agent's stdout.
    ///
    /// A blocking `read(2)` runs on its own `Thread` rather than on a
    /// cooperative executor thread, so a stalled agent never starves Swift
    /// concurrency — the same shape as the wire package's own `ByteReader`,
    /// which is internal to that package.
    ///
    /// - Parameters:
    ///   - descriptor: The read end of the agent's stdout pipe.
    ///   - state: The shared process bookkeeping; EOF and read failures
    ///     tear it down, which is what reaps an agent that died.
    ///   - continuation: The stream continuation fed each chunk.
    private static func startReader(
        descriptor: Int32,
        state: AgentProcessState,
        continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        let thread = Thread { readLoop(descriptor, state: state, into: continuation) }
        thread.name = "FoundationModelsACPClient.AgentProcess"
        thread.start()
    }

    /// Reads `descriptor` in a loop, yielding each chunk until EOF or a
    /// read failure, then tears the agent down and finishes the stream.
    ///
    /// - Parameters:
    ///   - descriptor: The descriptor to read; closed when the loop ends.
    ///   - state: The shared process bookkeeping to tear down.
    ///   - continuation: The stream continuation to feed and finish.
    private static func readLoop(
        _ descriptor: Int32,
        state: AgentProcessState,
        into continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: readBufferSize, alignment: 1)
        defer {
            buffer.deallocate()
            close(descriptor)
        }
        while true {
            let count = Darwin.read(descriptor, buffer, readBufferSize)
            if count > 0 {
                continuation.yield(Data(bytes: buffer, count: count))
            } else if count == 0 {
                // EOF: the agent died, or the teardown killed it. Either
                // way, the same idempotent teardown reaps it.
                state.terminateCurrent()
                continuation.finish()
                return
            } else if errno != EINTR {
                let failure = errno
                state.terminateCurrent()
                continuation.finish(throwing: AgentProcessError.readFailed(errno: failure))
                return
            }
        }
    }
}

/// The transport wired to one spawned agent's stdio.
///
/// `bytes` carries the agent's stdout; `write(_:)` feeds its stdin. Both
/// directions run through ``AgentProcessState``, so a torn-down agent fails
/// writes loud and finishes the byte stream.
struct AgentStdioTransport: ACPTransport {
    /// Incoming byte chunks read from the agent's stdout.
    let bytes: AsyncThrowingStream<Data, any Error>

    /// The shared process bookkeeping the writes go through.
    private let state: AgentProcessState

    /// Creates the transport over one spawned agent's state.
    ///
    /// - Parameters:
    ///   - bytes: The stream the reader thread feeds.
    ///   - state: The shared process bookkeeping.
    init(bytes: AsyncThrowingStream<Data, any Error>, state: AgentProcessState) {
        self.bytes = bytes
        self.state = state
    }

    /// Writes one whole frame to the agent's stdin as an indivisible unit.
    ///
    /// - Parameter data: The framed bytes to send.
    /// - Throws: ``AgentProcessError/writeFailed(errno:)`` when the agent's
    ///   stdin rejects the bytes, or
    ///   ``AgentProcessError/agentUnavailable`` after teardown.
    func write(_ data: Data) async throws {
        try state.writeToStdin(data)
    }
}

/// The shared, class-backed bookkeeping behind one ``AgentProcess``: the
/// live pid, the stdin write descriptor, and the registry the pid is
/// registered into.
///
/// A plain `final class` with a `Mutex` rather than an actor, for the
/// family's own reason: `deinit` cannot `await`, so the state it tears down
/// must be reachable synchronously.
final class AgentProcessState: Sendable {
    /// The live agent: its pid and the write end of its stdin pipe.
    private struct Live {
        /// The agent's pid, equal to its process-group id.
        var pid: pid_t
        /// The write end that feeds the agent's stdin.
        var stdinWriteDescriptor: Int32
    }

    /// The live agent, or `nil` before the record and after teardown.
    private let live = Mutex<Live?>(nil)

    /// The registry the recorded pid is registered into and deregistered
    /// from.
    private let registry: ProcessRegistry

    /// Creates empty bookkeeping backed by `registry`.
    ///
    /// - Parameter registry: The registry for the spawned pid.
    init(registry: ProcessRegistry) {
        self.registry = registry
    }

    /// The live pid, or `nil` after teardown.
    var pid: pid_t? {
        live.withLock { $0?.pid }
    }

    /// Records the freshly spawned agent and registers its pid.
    ///
    /// - Parameters:
    ///   - pid: The spawned pid.
    ///   - stdinWriteDescriptor: The write end of the agent's stdin pipe.
    func record(pid: pid_t, stdinWriteDescriptor: Int32) {
        live.withLock { $0 = Live(pid: pid, stdinWriteDescriptor: stdinWriteDescriptor) }
        registry.register(pid)
    }

    /// Writes one whole frame to the agent's stdin, under the same lock the
    /// teardown takes, so a write never races the descriptor close.
    ///
    /// - Parameter data: The framed bytes to write in full.
    /// - Throws: ``AgentProcessError/agentUnavailable`` after teardown, or
    ///   ``AgentProcessError/writeFailed(errno:)`` when the write fails.
    func writeToStdin(_ data: Data) throws {
        try live.withLock { current in
            guard let current else {
                throw AgentProcessError.agentUnavailable
            }
            try Self.fullyWrite(current.stdinWriteDescriptor, data)
        }
    }

    /// Group-kills and reaps the recorded agent, closes its stdin, and
    /// deregisters its pid. Idempotent by construction — the take-and-clear
    /// inside the lock — so every teardown trigger can call it safely, in
    /// any order, any number of times. A `killpg` of an already-dead group
    /// is a harmless `ESRCH`, and `waitpid` runs exactly one time per pid.
    func terminateCurrent() {
        let taken = live.withLock { current -> Live? in
            let recorded = current
            current = nil
            return recorded
        }
        guard let taken else { return }
        _ = killpg(taken.pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(taken.pid, &status, 0)
        close(taken.stdinWriteDescriptor)
        registry.deregister(taken.pid)
    }

    /// Owner teardown: once nothing retains this state, ARC runs the same
    /// idempotent teardown, so it is safe even after an explicit
    /// ``terminateCurrent()``.
    deinit {
        terminateCurrent()
    }

    /// Writes every byte of `data` to `descriptor` as one indivisible
    /// frame, looping past short writes and `EINTR` — the same shape as the
    /// wire package's own `fullWrite`, which is internal to that package.
    ///
    /// - Parameters:
    ///   - descriptor: The descriptor to write to.
    ///   - data: The framed bytes to write in full.
    /// - Throws: ``AgentProcessError/writeFailed(errno:)``.
    private static func fullyWrite(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentProcessError.writeFailed(errno: errno)
                }
                offset += written
            }
        }
    }
}
