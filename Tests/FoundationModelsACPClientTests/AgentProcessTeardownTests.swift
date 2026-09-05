import Darwin
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
// The children are `/bin/cat` and `/bin/sleep`, and not an ACP agent. The
// tests that spawn a real foreign agent over stdio live in the nested
// `IntegrationTests` package.

/// The command for a child that reads its stdin until end of file.
private let readingChildCommand = "/bin/cat"

/// The command for a child that ignores its stdin.
private let idleChildCommand = "/bin/sleep"

/// The number of seconds the idle child sleeps. It is long enough that the
/// child outlives the test unless the test kills it.
private let idleChildSeconds = "300"

/// The time limits the teardown tests use.
private enum TeardownTestDeadline {
    /// The number of milliseconds in ``reapTimeLimit``.
    private static let reapTimeLimitMilliseconds = 200

    /// The number of seconds in ``slack``.
    private static let slackSeconds = 2

    /// The longest time the teardown under test waits for the reap.
    static let reapTimeLimit: Duration = .milliseconds(reapTimeLimitMilliseconds)

    /// The extra time a teardown may take after ``reapTimeLimit`` before the
    /// test reads it as a hang.
    static let slack: Duration = .seconds(slackSeconds)
}

/// A child process that stays in the process group of this test runner.
private struct GroupMemberChild {
    /// The pid of the child. It is not a process-group leader.
    let pid: pid_t

    /// The write end of the pipe on the child's stdin.
    let stdinWriteDescriptor: Int32
}

/// Spawns `command` in the process group of this test runner, with its stdin
/// on a pipe.
///
/// No spawn attribute asks for a new process group, so `killpg` of the
/// child's pid reaches nothing.
///
/// - Parameters:
///   - command: The absolute path of the executable.
///   - arguments: The arguments to give it.
/// - Returns: The child's pid and this process's write end of its stdin.
private func spawnInThisProcessGroup(
    _ command: String, arguments: [String]
) throws -> GroupMemberChild {
    var descriptors: [Int32] = [0, 0]
    try #require(pipe(&descriptors) == 0)
    let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
    // The tests of this target run in parallel, and a spawned child inherits
    // every open descriptor of this process. Without `FD_CLOEXEC` the child
    // of one test holds a copy of the write end of the other test's pipe,
    // and that copy keeps the other child's stdin open after the teardown
    // closed its own copy. The `dup2` file action below still puts the read
    // end on the child's stdin: `dup2` clears the flag on the new descriptor.
    for descriptor in [readEnd, writeEnd] {
        try #require(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0)
    }

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_adddup2(&fileActions, readEnd, STDIN_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, readEnd)
    posix_spawn_file_actions_addclose(&fileActions, writeEnd)

    let argv: [UnsafeMutablePointer<CChar>?] = ([command] + arguments).map { strdup($0) } + [nil]
    defer { for case let pointer? in argv { free(pointer) } }

    var pid: pid_t = 0
    let spawnResult = posix_spawn(&pid, command, &fileActions, nil, argv, environ)
    close(readEnd)
    if spawnResult != 0 {
        close(writeEnd)
    }
    try #require(spawnResult == 0)
    return GroupMemberChild(pid: pid, stdinWriteDescriptor: writeEnd)
}

/// Tells whether the process table holds `pid`. A reaped child is gone from
/// the table; a live child and a zombie are both in it.
///
/// - Parameter pid: The pid to look for.
/// - Returns: `true` when `kill(pid, 0)` finds the process.
private func isInProcessTable(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

/// Kills `pid` and collects its exit status, so a child the teardown under
/// test did not reap never outlives the test. A no-op for a pid that is
/// already reaped.
///
/// - Parameter pid: The pid to kill and reap.
private func killAndReap(_ pid: pid_t) {
    _ = kill(pid, SIGKILL)
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
}

/// The teardown scenarios in which the group kill reaches nothing.
///
/// A teardown that blocks forever fails the time limit rather than hanging
/// the whole run.
@Suite("AgentProcessState teardown when the group kill misses", .timeLimit(.minutes(1)))
struct AgentProcessTeardownTests {
    /// A child that reads its stdin until end of file exits when the teardown
    /// closes that stdin. The teardown must close it BEFORE it waits, or the
    /// child never exits and the wait never ends.
    @Test func teardownReapsAnAgentTheGroupKillMissedOnceItsStdinCloses() throws {
        let child = try spawnInThisProcessGroup(readingChildCommand, arguments: [])
        defer { killAndReap(child.pid) }
        let signalResult = killpg(child.pid, 0)
        let signalError = errno
        #expect(signalResult == -1)
        #expect(signalError == ESRCH)

        let registry = ProcessRegistry()
        let state = AgentProcessState(
            registry: registry, reapTimeLimit: TeardownTestDeadline.reapTimeLimit
        )
        state.record(pid: child.pid, stdinWriteDescriptor: child.stdinWriteDescriptor)

        let elapsed = ContinuousClock().measure { state.terminateCurrent() }

        #expect(elapsed < TeardownTestDeadline.reapTimeLimit + TeardownTestDeadline.slack)
        #expect(state.pid == nil)
        #expect(registry.registeredPids.isEmpty)
        #expect(!isInProcessTable(child.pid))
    }

    /// A child that ignores its stdin outlives the teardown. The teardown must
    /// still return, by the reap time limit.
    @Test func teardownReturnsByTheDeadlineWhenTheAgentOutlivesTheGroupKill() throws {
        let child = try spawnInThisProcessGroup(idleChildCommand, arguments: [idleChildSeconds])
        defer { killAndReap(child.pid) }

        let registry = ProcessRegistry()
        let state = AgentProcessState(
            registry: registry, reapTimeLimit: TeardownTestDeadline.reapTimeLimit
        )
        state.record(pid: child.pid, stdinWriteDescriptor: child.stdinWriteDescriptor)

        let elapsed = ContinuousClock().measure { state.terminateCurrent() }

        #expect(elapsed >= TeardownTestDeadline.reapTimeLimit)
        #expect(elapsed < TeardownTestDeadline.reapTimeLimit + TeardownTestDeadline.slack)
        #expect(state.pid == nil)
        #expect(registry.registeredPids.isEmpty)
        #expect(isInProcessTable(child.pid))
    }
}
