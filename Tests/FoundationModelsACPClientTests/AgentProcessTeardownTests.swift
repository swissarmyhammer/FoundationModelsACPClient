import Darwin
import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPClient

// The teardown of `AgentProcessState` must return when the group kill reaches
// nothing. `killpg(pid, SIGKILL)` fails with `ESRCH` for a pid that is not a
// process-group leader, and a child that `posix_spawn` starts without
// `POSIX_SPAWN_SETPGROUP` is exactly that: it stays in the process group of
// this test runner. Each test here spawns such a child, records it in an
// `AgentProcessState` over a private registry, and runs the teardown.
//
// The reap waits on the first of two events: the exit event of the child, or
// the end of the reap time limit on the reap clock. Each test gives a manual
// clock, so no test reads the wall clock: a test whose child exits never moves
// the clock, and the test whose child never exits moves the clock past the
// limit after the reap waits.
//
// The children are the `StdioChild` commands, `/bin/cat`, `/bin/sleep` and a
// `/bin/sh` script, and not an ACP agent.

/// The reap time limit of the tests. The value has no effect on the duration
/// of a test: only the manual clock of the test moves past it.
private let reapTimeLimit: Duration = .seconds(5)

/// A child process that stays in the process group of this test runner.
private struct GroupMemberChild {
    /// The pid of the child. It is not a process-group leader.
    let pid: pid_t

    /// The write end of the pipe on the child's stdin.
    let stdinWriteDescriptor: Int32
}

/// The path the children of ``spawnInThisProcessGroup(command:arguments:)``
/// get as their stdout.
private let discardedOutputPath = "/dev/null"

/// Spawns `command` in the process group of this test runner, with its stdin
/// on a pipe and its stdout on ``discardedOutputPath``.
///
/// The spawn is the production spawn of `AgentProcess` with
/// ``ChildProcessGroup/inherited``, so `killpg` of the child's pid reaches
/// nothing. The tests of this target run in parallel, and that spawn gives
/// the child no descriptor of a parallel test: a copy of another test's
/// write end would keep that test's child stdin open after its teardown.
/// The child gets a stdout, because `cat` reports a closed stdout on the
/// stderr it keeps.
///
/// - Parameters:
///   - command: The absolute path of the executable.
///   - arguments: The arguments to give it.
/// - Returns: The child's pid and this process's write end of its stdin.
/// - Throws: The errors of `AgentProcess.createPipe()` and
///   `AgentProcess.spawnChild(command:arguments:descriptors:processGroup:environment:currentDirectory:)`.
private func spawnInThisProcessGroup(
    command: String, arguments: [String]
) throws -> GroupMemberChild {
    let discardedOutput = open(discardedOutputPath, O_WRONLY | O_CLOEXEC)
    try #require(discardedOutput >= 0)
    defer { close(discardedOutput) }
    let (readEnd, writeEnd) = try AgentProcess.createPipe()
    defer { close(readEnd) }
    do {
        let pid = try AgentProcess.spawnChild(
            command: command, arguments: arguments,
            descriptors: [
                (source: readEnd, target: STDIN_FILENO),
                (source: discardedOutput, target: STDOUT_FILENO),
            ],
            processGroup: .inherited
        )
        return GroupMemberChild(pid: pid, stdinWriteDescriptor: writeEnd)
    } catch {
        close(writeEnd)
        throw error
    }
}

/// Kills `pid` and collects its exit status, so a child the teardown under
/// test did not reap never outlives the test. A no-op for a pid that is
/// already reaped.
///
/// - Parameter pid: The pid to kill and reap.
private func killAndReap(pid: pid_t) {
    _ = kill(pid, SIGKILL)
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
}

/// Runs a teardown on a thread of its own, and waits for its end.
///
/// The teardown blocks its thread until its reap ends. A thread of its own
/// keeps the cooperative pool free for the reap clock and for the test body.
///
/// - Parameter state: The bookkeeping to tear down.
private func terminateOnAThreadOfItsOwn(_ state: AgentProcessState) async {
    await withCheckedContinuation { (ended: CheckedContinuation<Void, Never>) in
        Thread {
            state.terminateCurrent()
            ended.resume()
        }.start()
    }
}

/// Records `child` in an `AgentProcessState` with a manual reap clock that
/// never moves, runs the teardown, and expects that the teardown reaped the
/// child.
///
/// The clock never moves, so only the exit event of the child can end the
/// wait of the reap. A teardown that does not see the exit hangs, and a
/// `sample` of the test process shows where.
///
/// - Parameters:
///   - child: A child that exits once its stdin closes.
///   - sourceLocation: The location of the test that calls this helper.
private func expectTeardownReaps(
    _ child: GroupMemberChild, sourceLocation: SourceLocation = #_sourceLocation
) {
    let registry = ProcessRegistry()
    let state = AgentProcessState(registry: registry, reapTimeLimit: reapTimeLimit, reapClock: ManualClock())
    state.record(pid: child.pid, stdinWriteDescriptor: child.stdinWriteDescriptor)

    state.terminateCurrent()

    #expect(state.pid == nil, sourceLocation: sourceLocation)
    #expect(registry.registeredPids.isEmpty, sourceLocation: sourceLocation)
    #expect(!StdioChild.isInProcessTable(pid: child.pid), sourceLocation: sourceLocation)
    #expect(state.exitStatus != nil && state.exitStatus != .notCollected, sourceLocation: sourceLocation)
}

/// The teardown scenarios in which the group kill reaches nothing.
@Suite("AgentProcessState teardown when the group kill misses")
struct AgentProcessTeardownTests {
    /// A child that reads its stdin until end of file exits when the teardown
    /// closes that stdin. The teardown must close it BEFORE it waits, or the
    /// child never exits and the wait never ends.
    @Test func teardownReapsAnAgentTheGroupKillMissedOnceItsStdinCloses() throws {
        let child = try spawnInThisProcessGroup(command: StdioChild.readingCommand, arguments: [])
        defer { killAndReap(pid: child.pid) }
        let signalResult = killpg(child.pid, 0)
        let signalError = errno
        #expect(signalResult == -1)
        #expect(signalError == ESRCH)

        expectTeardownReaps(child)
    }

    /// A child can exit late after the teardown closes its stdin: a loaded
    /// machine schedules it late, or a parallel spawn holds a copy of the
    /// write end for a short time. The teardown must wait for the exit event
    /// of the child, and not for a guess of how fast the exit comes.
    @Test func teardownReapsAnAgentThatExitsLateAfterItsStdinCloses() throws {
        let child = try spawnInThisProcessGroup(
            command: StdioChild.slowReadingCommand, arguments: StdioChild.slowReadingScript
        )
        defer { killAndReap(pid: child.pid) }

        expectTeardownReaps(child)
    }

    /// A child that ignores its stdin outlives the teardown. The teardown
    /// must return when the reap time limit passes on the reap clock, and
    /// not before.
    ///
    /// The order is fixed: the teardown waits on the clock (one sleeper), the
    /// test checks that the teardown did not end, the test moves the clock
    /// past the limit, and the teardown ends with the child still alive.
    @MainActor @Test func teardownReturnsWhenTheReapLimitPassesWhileTheAgentOutlivesTheGroupKill() async throws {
        let child = try spawnInThisProcessGroup(
            command: StdioChild.idleCommand, arguments: [StdioChild.idleSeconds]
        )
        defer { killAndReap(pid: child.pid) }
        let clock = ManualClock()
        let registry = ProcessRegistry()
        let state = AgentProcessState(registry: registry, reapTimeLimit: reapTimeLimit, reapClock: clock)
        state.record(pid: child.pid, stdinWriteDescriptor: child.stdinWriteDescriptor)

        let teardown = Task.detached { await terminateOnAThreadOfItsOwn(state) }
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(state.exitStatus == nil, "The teardown ended before the reap limit passed.")

        clock.advance(by: reapTimeLimit)
        await teardown.value

        #expect(state.pid == nil)
        #expect(registry.registeredPids.isEmpty)
        #expect(state.exitStatus == .notCollected)
        #expect(StdioChild.isInProcessTable(pid: child.pid))
    }
}
