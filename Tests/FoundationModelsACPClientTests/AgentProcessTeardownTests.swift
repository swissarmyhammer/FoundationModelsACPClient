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
// The children are the `StdioChild` commands, `/bin/cat`, `/bin/sleep` and a
// `/bin/sh` script, and not an ACP agent. The tests that spawn a real foreign
// agent over stdio live in the nested `IntegrationTests` package.

/// The time limits of the test whose child never exits.
///
/// The tests whose child exits do not use these limits. Their teardown waits
/// for the exit of the child, and ``AgentProcessState/defaultReapTimeLimit``
/// is only the bound that shows a hang. A short limit there is a guess of how
/// fast the child exits, and a loaded machine makes that guess wrong.
private enum TeardownTestDeadline {
    /// The number of milliseconds in ``reapTimeLimit``.
    private static let reapTimeLimitMilliseconds = 200

    /// The number of seconds in ``slack``.
    private static let slackSeconds = 2

    /// The longest time the teardown under test waits for a child that never
    /// exits. The teardown waits all of it.
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
    command: String, arguments: [String]
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

    // The flag above cannot close a race: a parallel test can open its pipe
    // and spawn its child before it sets `FD_CLOEXEC`, and between those two
    // calls this spawn gets a copy of that pipe. `POSIX_SPAWN_CLOEXEC_DEFAULT`
    // closes every descriptor the file actions do not name, so the child of
    // this spawn holds its own stdin and no descriptor of a parallel test.
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

    let argv: [UnsafeMutablePointer<CChar>?] = ([command] + arguments).map { strdup($0) } + [nil]
    defer { for case let pointer? in argv { free(pointer) } }

    var pid: pid_t = 0
    let spawnResult = posix_spawn(&pid, command, &fileActions, &attributes, argv, environ)
    close(readEnd)
    if spawnResult != 0 {
        close(writeEnd)
    }
    try #require(spawnResult == 0)
    return GroupMemberChild(pid: pid, stdinWriteDescriptor: writeEnd)
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

/// Records `child` in an `AgentProcessState` with the production reap time
/// limit, runs the teardown, and expects that the teardown reaped the child.
///
/// The teardown ends its wait on an event: the child exits, and `waitpid`
/// collects it. The production limit is only the bound that shows a hang, so
/// the result does not depend on how fast a loaded machine runs the child.
///
/// - Parameters:
///   - child: A child that exits once its stdin closes.
///   - sourceLocation: The location of the test that calls this helper.
private func expectTeardownReaps(
    _ child: GroupMemberChild, sourceLocation: SourceLocation = #_sourceLocation
) {
    let registry = ProcessRegistry()
    let state = AgentProcessState(registry: registry)
    state.record(pid: child.pid, stdinWriteDescriptor: child.stdinWriteDescriptor)

    let elapsed = ContinuousClock().measure { state.terminateCurrent() }

    #expect(elapsed < AgentProcessState.defaultReapTimeLimit, sourceLocation: sourceLocation)
    #expect(state.pid == nil, sourceLocation: sourceLocation)
    #expect(registry.registeredPids.isEmpty, sourceLocation: sourceLocation)
    #expect(!StdioChild.isInProcessTable(pid: child.pid), sourceLocation: sourceLocation)
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
    /// write end for a short time. The teardown must wait for the exit of
    /// the child, and not for a guess of how fast the exit comes.
    @Test func teardownReapsAnAgentThatExitsLateAfterItsStdinCloses() throws {
        let child = try spawnInThisProcessGroup(
            command: StdioChild.slowReadingCommand, arguments: StdioChild.slowReadingScript
        )
        defer { killAndReap(pid: child.pid) }

        expectTeardownReaps(child)
    }

    /// A child that ignores its stdin outlives the teardown. The teardown must
    /// still return, by the reap time limit.
    @Test func teardownReturnsByTheDeadlineWhenTheAgentOutlivesTheGroupKill() throws {
        let child = try spawnInThisProcessGroup(
            command: StdioChild.idleCommand, arguments: [StdioChild.idleSeconds]
        )
        defer { killAndReap(pid: child.pid) }

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
        #expect(StdioChild.isInProcessTable(pid: child.pid))
    }
}
