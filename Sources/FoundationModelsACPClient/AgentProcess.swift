// `AgentProcess` — this package owns the lifecycle of the external agent it
// spawns over stdio, because no other party can end that process. It mirrors
// the family discipline that `FoundationModelsShelltool` and
// `FoundationModelsMCP` (`StdioServerProcess`) already implement: spawn in
// the child's own process group, so the agent's own children die with it;
// register the pid in a `ProcessRegistry`; group-kill *and* reap on every
// teardown path; and backstop everything with the same `atexit` sweep and
// the same honestly-stated limitation — a normal exit only, never `SIGKILL`
// or a crash.
//
// `ProcessRegistry`, its `sweep(_:)`, and the `atexit`-installed
// `ProcessRegistry.global` come from `FoundationModelsExtras`, the family
// leaf that owns them. This package depends on the ACP wire and on that
// leaf, so every consumer in one host process shares one registry and one
// sweep rather than each package sweeping a global of its own.
//
// What this file owns is the rest of the discipline: the process-group
// spawn, the group kill, the reap, and the three teardown triggers.
//
// The group kill can miss — `killpg` fails with `ESRCH` for a pid that is no
// longer a group leader, and with `EPERM` for a group this process may not
// signal — so the teardown never depends on it. It closes the agent's stdin
// BEFORE it waits, which is the EOF an ACP agent exits on, and it polls the
// reap with `WNOHANG` up to a time limit. A teardown therefore always
// returns; a leak is the worst case, never a hang.
//
// Spawning goes through raw `posix_spawn` rather than `Foundation.Process`,
// for the sibling's own reason: `Process` gives no public way to put a child
// in its own process group before it execs, and
// `POSIX_SPAWN_SETPGROUP`/`posix_spawnattr_setpgroup(0)` sets the group
// atomically as a part of the spawn. `POSIX_SPAWN_CLOEXEC_DEFAULT` in the same
// spawn gives the agent its stdin, its stdout and the host's stderr, and no
// other descriptor, whatever another thread of the host opens at that time.
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
import FoundationModelsExtras
import Synchronization

/// A failure while constructing an ``AgentProcess`` or while speaking to
/// its agent.
public enum AgentProcessError: Error, Equatable, CustomStringConvertible {
    /// ``AgentProcess/init(command:arguments:environment:currentDirectory:)``
    /// got a `command` that is not an absolute path.
    ///
    /// This package requires an absolute path rather than a `PATH` lookup,
    /// for the family's own reason: a relative lookup would have to select
    /// *which* `PATH` applies. A caller that only has a bare command name
    /// must resolve it to an absolute path first.
    case commandNotAbsolute(String)

    /// Creating the stdin or stdout pipe failed, or one of its ends could
    /// not take the `FD_CLOEXEC` flag; carries the C `errno`.
    case pipeCreationFailed(errno: Int32)

    /// `posix_spawn` itself failed; carries the `command` path and the
    /// error number `posix_spawn` returned directly. A working directory that
    /// the child cannot enter fails the spawn too.
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

    /// The whole environment given to the agent at the spawn, or `nil` when
    /// the agent got the environment of this process.
    public let environment: [String: String]?

    /// The working directory the agent started in, or `nil` when the agent
    /// started in the working directory of this process.
    public let currentDirectory: String?

    /// The transport wired to the agent's stdio. Hand it to
    /// ``ConnectionModel/connect(over:logger:bufferLimits:client:)``.
    public let transport: any ACPTransport

    /// The shared, class-backed process bookkeeping every copy of this
    /// value refers to.
    private let state: AgentProcessState

    /// Spawns the agent process, in its own process group, and wires its
    /// stdio to ``transport``.
    ///
    /// The child gets the stderr of this process. The child gets the
    /// environment and the working directory of this process unless the
    /// caller gives others, so a host needs no `/usr/bin/env` wrapper to set
    /// them.
    ///
    /// - Parameters:
    ///   - command: The absolute path of the agent executable.
    ///   - arguments: The arguments to give to the agent.
    ///   - environment: The whole environment of the agent, or `nil` to give
    ///     it the environment of this process. A dictionary replaces the
    ///     environment of this process; it does not add to it.
    ///   - currentDirectory: The working directory the agent starts in, or
    ///     `nil` to start it in the working directory of this process. A
    ///     relative path is relative to the working directory of this
    ///     process.
    /// - Throws: ``AgentProcessError/commandNotAbsolute(_:)`` for a
    ///   relative `command`, ``AgentProcessError/pipeCreationFailed(errno:)``
    ///   when a pipe cannot be made, or
    ///   ``AgentProcessError/spawnFailed(command:errno:)`` when
    ///   `posix_spawn` itself fails, also for a `currentDirectory` that the
    ///   child cannot enter.
    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) throws {
        try self.init(
            command: command,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            registry: .global
        )
    }

    /// Spawns the agent process and registers its pid in `registry`.
    ///
    /// ``init(command:arguments:environment:currentDirectory:)`` registers in
    /// `ProcessRegistry.global`, the registry every process this package
    /// starts shares. A unit test spawns into a registry of its own, so its
    /// pids never reach the process-wide registry that other tests read at
    /// the same time.
    ///
    /// - Parameters:
    ///   - command: The absolute path of the agent executable.
    ///   - arguments: The arguments to give to the agent.
    ///   - environment: The whole environment of the agent, or `nil` for the
    ///     environment of this process.
    ///   - currentDirectory: The working directory of the agent, or `nil`
    ///     for the working directory of this process.
    ///   - registry: The registry for the spawned pid.
    /// - Throws: The errors of
    ///   ``init(command:arguments:environment:currentDirectory:)``.
    init(
        command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        registry: ProcessRegistry
    ) throws {
        guard command.hasPrefix("/") else {
            throw AgentProcessError.commandNotAbsolute(command)
        }
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory

        let spawned = try Self.spawn(
            command: command,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory
        )
        let state = AgentProcessState(registry: registry)
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

    /// How the agent ended, or `nil` while the teardown has not reaped it.
    ///
    /// The teardown records the status when it reaps the agent: after the
    /// agent ended by itself, after ``shutdown()``, or after the transport
    /// ended. ``waitForExit()`` waits for the same value.
    public var exitStatus: AgentExitStatus? { state.exitStatus }

    /// Waits until the teardown reaped the agent, and gives how it ended.
    ///
    /// This call does not end the agent. It returns when the agent ends by
    /// itself (its stdout closes), or when the host calls ``shutdown()`` or
    /// ends the transport. A call after the end returns at once.
    ///
    /// - Returns: How the agent ended. ``AgentExitStatus/notCollected``
    ///   tells that the teardown did not collect the agent in its time limit.
    /// - Throws: `CancellationError` when the task of the caller is
    ///   cancelled before the end.
    public func waitForExit() async throws -> AgentExitStatus {
        try await state.waitForExit()
    }

    /// Group-kills and reaps the agent. Idempotent; a no-op when the agent
    /// is already torn down.
    ///
    /// This call always returns. The teardown closes the agent's stdin
    /// before it waits, and the wait for the reap is bounded, so an agent
    /// the group kill did not reach cannot block the host.
    public func shutdown() {
        state.terminateCurrent()
    }

    /// Closes the agent's stdin and leaves the agent running.
    ///
    /// This is the polite half of a teardown, and it is the only way to ask an
    /// agent to end on its own terms: an ACP agent reads its stdin until EOF,
    /// so a closed stdin is the wire's own "no more requests are coming".
    /// ``shutdown()`` is the impolite half, and it never asks.
    ///
    /// A caller that wants the agent gone still runs ``shutdown()`` after.
    /// Nothing here waits, nothing here kills, and an agent that ignores the
    /// EOF keeps running.
    ///
    /// Idempotent, and a no-op after teardown. Every ``write(_:)`` after this
    /// call fails with ``AgentProcessError/agentUnavailable``.
    public func closeStandardInput() {
        state.closeStandardInput()
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

    /// Spawns `command` in its own process group, with its stdin and stdout
    /// piped to this process.
    ///
    /// - Parameters:
    ///   - command: The absolute path of the executable.
    ///   - arguments: The arguments to give it.
    ///   - environment: The whole environment of the child, or `nil` for the
    ///     environment of this process.
    ///   - currentDirectory: The working directory of the child, or `nil`
    ///     for the working directory of this process.
    /// - Returns: The spawned pid and this process's pipe ends.
    /// - Throws: ``AgentProcessError/pipeCreationFailed(errno:)`` or
    ///   ``AgentProcessError/spawnFailed(command:errno:)``.
    private static func spawn(
        command: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?
    ) throws -> Spawned {
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
                descriptors: [
                    (source: stdinRead, target: STDIN_FILENO),
                    (source: stdoutWrite, target: STDOUT_FILENO),
                ],
                processGroup: .own,
                environment: environment,
                currentDirectory: currentDirectory
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

        // The child holds its own copies of these two ends now. The spawn
        // never closes a descriptor in this process, so the ends must be
        // closed here or each spawn leaks two descriptors.
        close(stdinRead)
        close(stdoutWrite)

        return Spawned(pid: pid, stdinWriteDescriptor: stdinWrite, stdoutReadDescriptor: stdoutRead)
    }

    /// Creates a pipe with `FD_CLOEXEC` on both ends, and returns its read
    /// and write ends.
    ///
    /// A child that `posix_spawn` starts without `POSIX_SPAWN_CLOEXEC_DEFAULT`
    /// inherits every open descriptor of this process that does not carry
    /// `FD_CLOEXEC`. Such a child, which another part of this process spawns
    /// while this agent is live, gets the two ends only when they lack the
    /// flag. Its copy of the write end would keep this agent's stdin open
    /// after ``closeStandardInput()`` closed this process's own copy, so the
    /// agent would never read its end of file.
    ///
    /// The flag alone does not close that hole. `pipe(2)` and `fcntl(2)` are
    /// two calls, and another thread can spawn a child between them; that
    /// child gets both ends before the flag is on. Only a spawn that names
    /// the descriptors its child keeps is free of the race, and
    /// ``spawnChild(command:arguments:descriptors:processGroup:environment:currentDirectory:)``
    /// is that spawn for each child of this package. The flag here is the
    /// guard for the spawns of other code in this process, after the second
    /// call.
    ///
    /// The `dup2` file action still puts the child's end on descriptor 0 or
    /// 1, because `dup2` clears the flag on the new descriptor.
    ///
    /// - Returns: The `(readEnd, writeEnd)` pair from `pipe(2)`, each with
    ///   `FD_CLOEXEC` set.
    /// - Throws: ``AgentProcessError/pipeCreationFailed(errno:)`` when
    ///   `pipe(2)` fails, or when the flag cannot be set on an end. No
    ///   descriptor stays open after a throw.
    static func createPipe() throws -> (readEnd: Int32, writeEnd: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw AgentProcessError.pipeCreationFailed(errno: errno)
        }
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                let failure = errno
                for descriptor in descriptors {
                    close(descriptor)
                }
                throw AgentProcessError.pipeCreationFailed(errno: failure)
            }
        }
        return (descriptors[0], descriptors[1])
    }

    /// Performs the `posix_spawn` call: puts each source descriptor of
    /// `descriptors` on its target descriptor in the child, keeps the stderr
    /// of this process, and closes every other descriptor in the child.
    ///
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` closes, at the exec, each descriptor
    /// that the file actions do not name. The `dup2` targets and stderr are
    /// the only names, so the child holds those descriptors and nothing else.
    /// That holds whatever another thread of this process opens at the same
    /// time, with or without `FD_CLOEXEC`.
    ///
    /// - Parameters:
    ///   - command: The absolute path of the executable.
    ///   - arguments: The arguments to give it.
    ///   - descriptors: Each descriptor of this process that the child gets,
    ///     and the descriptor number it gets in the child. This process keeps
    ///     its own copies, and the caller closes them.
    ///   - processGroup: The process group the child joins.
    ///   - environment: The whole environment of the child, or `nil` for the
    ///     environment of this process.
    ///   - currentDirectory: The working directory of the child, or `nil`
    ///     for the working directory of this process.
    /// - Returns: The spawned pid.
    /// - Throws: ``AgentProcessError/spawnFailed(command:errno:)``, also when
    ///   the child cannot enter `currentDirectory`.
    static func spawnChild(
        command: String, arguments: [String],
        descriptors: [(source: Int32, target: Int32)],
        processGroup: ChildProcessGroup,
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in descriptors {
            posix_spawn_file_actions_adddup2(&fileActions, descriptor.source, descriptor.target)
        }
        // The child writes its diagnostics to the stderr of this process, so
        // that they never reach the wire on its stdout.
        posix_spawn_file_actions_addinherit_np(&fileActions, STDERR_FILENO)
        // The change of directory is a file action, so it occurs in the child
        // before the exec, and the directory of this process stays the same.
        // The command is an absolute path, so the change does not move it.
        if let currentDirectory {
            posix_spawn_file_actions_addchdir(&fileActions, currentDirectory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(processGroup.spawnFlags | POSIX_SPAWN_CLOEXEC_DEFAULT))
        // The spawn reads the group only with `POSIX_SPAWN_SETPGROUP`, and
        // `0` makes the child the leader of a new group.
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = cStrings([command] + arguments)
        defer { freePointers(argv) }

        var pid: pid_t = 0
        let spawnResult = withEnvironmentBlock(environment) { envp in
            posix_spawn(&pid, command, &fileActions, &attributes, argv, envp)
        }
        guard spawnResult == 0 else {
            throw AgentProcessError.spawnFailed(command: command, errno: spawnResult)
        }
        return pid
    }

    /// Gives `body` the `envp` block for a spawn: the environment of this
    /// process for `nil`, or else one `NAME=value` entry for each pair of
    /// `environment`, in name order, with a `nil` terminator.
    ///
    /// The block of a dictionary lives only while `body` runs.
    ///
    /// - Parameters:
    ///   - environment: The whole environment of the child, or `nil` for the
    ///     environment of this process.
    ///   - body: The work that reads the block.
    /// - Returns: The result of `body`.
    private static func withEnvironmentBlock<Result>(
        _ environment: [String: String]?,
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        guard let environment else {
            return body(UnsafePointer(environ))
        }
        let entries = environment.map { name, value in "\(name)=\(value)" }.sorted()
        let block = cStrings(entries)
        defer { freePointers(block) }
        return block.withUnsafeBufferPointer { body($0.baseAddress) }
    }

    /// Copies each string into a `strdup`'d C string, and adds the `nil`
    /// terminator that `argv` and `envp` need.
    ///
    /// - Parameter strings: The strings to copy.
    /// - Returns: The C strings and the terminator. The caller frees them
    ///   with ``freePointers(_:)``.
    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
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

    /// The read buffer size in bytes (64 KiB), large enough to drain a
    /// typical pipe burst in one syscall — the same size the wire package's
    /// own reader uses.
    private static let readBufferSize = 65536

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

/// The process group that a child of
/// ``AgentProcess/spawnChild(command:arguments:descriptors:processGroup:environment:currentDirectory:)``
/// joins.
enum ChildProcessGroup {
    /// A new process group, with the child as its leader. `killpg` of the
    /// child's pid then reaches the child and every process it starts.
    case own

    /// The process group of this process. The child is not a group leader,
    /// so `killpg` of its pid reaches nothing.
    case inherited

    /// The `posix_spawnattr_setflags` bits that put the child in this group.
    var spawnFlags: Int32 {
        switch self {
        case .own:
            return POSIX_SPAWN_SETPGROUP
        case .inherited:
            return 0
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
/// live pid, the stdin write descriptor, the registry the pid is registered
/// into, and the exit status the teardown records.
///
/// A plain `final class` with a `Mutex` rather than an actor, for the
/// family's own reason: `deinit` cannot `await`, so the state it tears down
/// must be reachable synchronously.
final class AgentProcessState: Sendable {
    /// The live agent: its pid and the write end of its stdin pipe.
    private struct Live {
        /// The agent's pid, equal to its process-group id.
        var pid: pid_t
        /// The write end that feeds the agent's stdin, or `nil` once that end
        /// is closed. A closed stdin leaves the agent live: it is the EOF the
        /// agent reads, and not the end of the agent.
        var stdinWriteDescriptor: Int32?
    }

    /// The live agent, or `nil` before the record and after teardown.
    private let live = Mutex<Live?>(nil)

    /// The registry the recorded pid is registered into and deregistered
    /// from.
    private let registry: ProcessRegistry

    /// The exit status that ``terminateCurrent()`` records, and the callers
    /// that wait for it.
    private let exitLatch = AgentExitLatch()

    /// The number of seconds in ``defaultReapTimeLimit``.
    private static let defaultReapTimeLimitSeconds = 5

    /// The longest time a teardown waits for the reap of the agent, unless
    /// ``init(registry:reapTimeLimit:)`` gets a different limit.
    ///
    /// `SIGKILL` ends a process at once, so a reap that needs more time than
    /// this is a process the signal did not reach. The teardown then returns
    /// without the reap, rather than block the host forever.
    static let defaultReapTimeLimit: Duration = .seconds(defaultReapTimeLimitSeconds)

    /// The longest time ``terminateCurrent()`` waits for the reap.
    private let reapTimeLimit: Duration

    /// Creates empty bookkeeping backed by `registry`.
    ///
    /// - Parameters:
    ///   - registry: The registry for the spawned pid.
    ///   - reapTimeLimit: The longest time ``terminateCurrent()`` waits for
    ///     the reap. Tests give a short limit, so a teardown that must give
    ///     up does so in a fraction of a second.
    init(
        registry: ProcessRegistry,
        reapTimeLimit: Duration = AgentProcessState.defaultReapTimeLimit
    ) {
        self.registry = registry
        self.reapTimeLimit = reapTimeLimit
    }

    /// The live pid, or `nil` after teardown.
    var pid: pid_t? {
        live.withLock { $0?.pid }
    }

    /// How the agent ended, or `nil` before ``terminateCurrent()`` reaped
    /// it.
    var exitStatus: AgentExitStatus? {
        exitLatch.status
    }

    /// Waits until ``terminateCurrent()`` records how the agent ended.
    ///
    /// - Returns: How the agent ended.
    /// - Throws: `CancellationError` when the task of the caller is
    ///   cancelled before the record.
    func waitForExit() async throws -> AgentExitStatus {
        try await exitLatch.wait()
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
            guard let descriptor = current?.stdinWriteDescriptor else {
                throw AgentProcessError.agentUnavailable
            }
            try Self.fullyWrite(descriptor, data)
        }
    }

    /// Closes the agent's stdin and keeps the agent recorded.
    ///
    /// The take-and-clear of the descriptor happens inside the same lock every
    /// write and every teardown takes, so the close never races a write and no
    /// descriptor is closed twice. The pid stays, because the agent stays: this
    /// hands the agent an EOF and nothing else.
    func closeStandardInput() {
        let taken = live.withLock { current -> Int32? in
            let descriptor = current?.stdinWriteDescriptor
            current?.stdinWriteDescriptor = nil
            return descriptor
        }
        guard let taken else { return }
        close(taken)
    }

    /// Group-kills the recorded agent, closes its stdin, reaps it with a
    /// bounded wait, and deregisters its pid. Idempotent by construction —
    /// the take-and-clear inside the lock — so every teardown trigger can
    /// call it safely, in any order, any number of times. A `killpg` of an
    /// already-dead group is a harmless `ESRCH`, and the reap runs exactly
    /// one time per pid. A stdin ``closeStandardInput()`` already closed is
    /// left alone.
    ///
    /// The stdin close comes BEFORE the wait, and the wait is bounded, so
    /// this call always returns. The group kill can miss: `killpg` fails
    /// with `ESRCH` for a pid that is no longer a group leader, and with
    /// `EPERM` for a group this process may not signal. An agent the signal
    /// did not reach still reads the EOF, and an ACP agent exits on it. An
    /// agent that ignores both stays alive after the reap time limit ends,
    /// rather than block the host forever.
    ///
    /// The teardown records how the agent ended after the reap, and after
    /// the deregister, so a caller that ``waitForExit()`` resumes finds the
    /// pid gone from the registry.
    func terminateCurrent() {
        let taken = live.withLock { current -> Live? in
            let recorded = current
            current = nil
            return recorded
        }
        guard let taken else { return }
        _ = killpg(taken.pid, SIGKILL)
        if let descriptor = taken.stdinWriteDescriptor {
            close(descriptor)
        }
        let status = reap(pid: taken.pid)
        registry.deregister(taken.pid)
        exitLatch.record(status)
    }

    /// The number of milliseconds in ``reapPollInterval``.
    private static let reapPollIntervalMilliseconds = 10

    /// The pause between two polls of the reap.
    private static let reapPollInterval: Duration = .milliseconds(reapPollIntervalMilliseconds)

    /// Collects the exit status of `pid` without a blocking wait: a `WNOHANG`
    /// poll, repeated at ``reapPollInterval`` until the child is collected or
    /// the reap time limit ends.
    ///
    /// `waitpid` answers `0` while the child still runs, the pid when it has
    /// collected the child, and `-1` when there is nothing to collect: a pid
    /// that is not a child of this process, or a child already collected.
    /// Only the first answer is a reason to poll again.
    ///
    /// - Parameter pid: The pid to collect.
    /// - Returns: How the child ended, decoded from the status `waitpid`
    ///   wrote, or ``AgentExitStatus/notCollected`` when no answer collected
    ///   the child.
    private func reap(pid: pid_t) -> AgentExitStatus {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: reapTimeLimit)
        var status: Int32 = 0
        var answer = waitpid(pid, &status, WNOHANG)
        while answer == 0, clock.now < deadline {
            Thread.sleep(forTimeInterval: Self.reapPollInterval / .seconds(1))
            answer = waitpid(pid, &status, WNOHANG)
        }
        guard answer == pid else {
            return .notCollected
        }
        return AgentExitStatus(waitStatus: status)
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
