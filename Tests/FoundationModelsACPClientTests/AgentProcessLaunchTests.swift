import Darwin
import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPClient

// A host sets the environment and the working directory of the agent, and
// reads the exit status of the agent after it ends. The host needs no
// `/usr/bin/env` wrapper for the first two.
//
// The children here are `/usr/bin/env`, `/bin/pwd`, `/bin/sleep` and a
// `/bin/sh` script, and not an ACP agent. Each child registers in a private
// registry, so a test that reads `ProcessRegistry.global` beside this one sees
// no pid of this test.

/// The launch settings of a child and the exit status of a child.
///
/// A test that waits for an end that never comes fails its time limit rather
/// than hanging the whole run.
@Suite("AgentProcess launch settings and exit status", .timeLimit(.minutes(1)))
struct AgentProcessLaunchTests {
    /// The name of the one variable the environment tests give the child.
    private static let variableName = "AGENT_PROCESS_PROBE"

    /// The value of ``variableName``.
    private static let variableValue = "given value"

    /// The status the exiting child exits with. It is not zero, so the test
    /// tells a real status from a default.
    private static let nonzeroExitStatus: Int32 = 3

    /// The child gets the given environment, and no variable of this process.
    @Test func childGetsOnlyTheGivenEnvironment() async throws {
        let child = try AgentProcess(
            command: StdioChild.environmentPrinterCommand,
            environment: [Self.variableName: Self.variableValue],
            registry: ProcessRegistry()
        )
        defer { child.shutdown() }

        let output = await StdioChild.wholeStandardOutput(of: child)

        #expect(output == "\(Self.variableName)=\(Self.variableValue)\n")
    }

    /// The child starts in the given working directory.
    @Test func childStartsInTheGivenDirectory() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let child = try AgentProcess(
            command: StdioChild.directoryPrinterCommand,
            arguments: StdioChild.directoryPrinterArguments,
            currentDirectory: directory.path,
            registry: ProcessRegistry()
        )
        defer { child.shutdown() }

        let output = await StdioChild.wholeStandardOutput(of: child)

        #expect(output == "\(try directory.physicalPath())\n")
    }

    /// A working directory that does not exist fails the spawn, and no child
    /// starts.
    @Test func missingDirectoryFailsTheSpawn() throws {
        let directory = try TemporaryDirectory()
        directory.remove()

        #expect(
            throws: AgentProcessError.spawnFailed(command: StdioChild.directoryPrinterCommand, errno: ENOENT)
        ) {
            _ = try AgentProcess(
                command: StdioChild.directoryPrinterCommand,
                currentDirectory: directory.path,
                registry: ProcessRegistry()
            )
        }
    }

    /// A child that exits by itself with a status that is not zero gives that
    /// status to a host that awaits the exit.
    @Test func hostAwaitsTheNonzeroExitStatus() async throws {
        let child = try AgentProcess(
            command: StdioChild.exitingCommand,
            arguments: StdioChild.exitingArguments(status: Self.nonzeroExitStatus),
            registry: ProcessRegistry()
        )
        defer { child.shutdown() }

        let status = await outcome { try? await child.waitForExit() } ?? nil

        #expect(status == .exited(code: Self.nonzeroExitStatus))
        #expect(child.exitStatus == .exited(code: Self.nonzeroExitStatus))
    }

    /// A live child has no exit status. A shutdown kills it with `SIGKILL`,
    /// and the exit status then names that signal.
    @Test func shutdownRecordsTheKillSignal() throws {
        let child = try AgentProcess(
            command: StdioChild.idleCommand, arguments: [StdioChild.idleSeconds], registry: ProcessRegistry()
        )
        #expect(child.exitStatus == nil)

        child.shutdown()

        #expect(child.exitStatus == .signaled(signal: SIGKILL))
    }

    /// A cancel of the task that awaits the exit ends the wait with
    /// `CancellationError`, and the child stays live.
    @Test func cancelEndsTheWaitForTheExit() async throws {
        let child = try AgentProcess(
            command: StdioChild.idleCommand, arguments: [StdioChild.idleSeconds], registry: ProcessRegistry()
        )
        defer { child.shutdown() }

        let waiter = Task { try await child.waitForExit() }
        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(child.exitStatus == nil)
    }
}

/// A new empty directory under the temporary directory of this process.
private struct TemporaryDirectory {
    /// The path of the directory, as the test gives it to the child.
    let path: String

    /// Makes the directory.
    ///
    /// - Throws: The error of `FileManager.createDirectory(atPath:withIntermediateDirectories:attributes:)`.
    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    /// The path with each symbolic link resolved, which is what `pwd -P`
    /// writes. The temporary directory of macOS is under `/var`, which is a
    /// link to `/private/var`.
    ///
    /// - Returns: The physical path of the directory.
    /// - Throws: An error of `#require` when `realpath(3)` fails.
    func physicalPath() throws -> String {
        let resolved = try #require(realpath(path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Removes the directory. A directory that is already gone is not an
    /// error.
    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
