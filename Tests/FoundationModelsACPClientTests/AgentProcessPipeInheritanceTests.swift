import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPClient

// A child that `posix_spawn` starts inherits every open descriptor of this
// process that does not carry `FD_CLOEXEC`, unless the spawn sets
// `POSIX_SPAWN_CLOEXEC_DEFAULT`. A second agent, which this process spawns
// while the first agent is live, must not get copies of the pipe ends of the
// first agent: a copy of the write end of the first agent's stdin keeps that
// stdin open after this process closed its own copy, and the first agent then
// never reads its end of file. The flag on a pipe end comes one call after
// `pipe(2)`, so the agent must also hold no descriptor that lacks the flag.
//
// The agents here are `/bin/cat`, `/bin/sleep` and a `/bin/sh` probe, and not
// an ACP agent. The tests that spawn a real foreign agent over stdio live in
// the nested `IntegrationTests` package. The agents register in a private
// registry, so a test that reads `ProcessRegistry.global` beside this one sees
// no pid of this test.

/// The scenario in which two agents live at the same time.
///
/// A test that waits for an end of file that never comes fails its time
/// limit rather than hanging the whole run.
@Suite("AgentProcess pipe inheritance", .timeLimit(.minutes(1)))
struct AgentProcessPipeInheritanceTests {
    /// The first agent reads its stdin until end of file. A close of that
    /// stdin must reach it as end of file while a second agent, spawned
    /// after it, is alive. The end of file ends the first agent, and the
    /// reader then ends the byte stream, reaps it, and deregisters it.
    @Test func stdinCloseReachesTheFirstAgentWhileASecondAgentLives() async throws {
        let registry = ProcessRegistry()
        let reader = try AgentProcess(command: StdioChild.readingCommand, registry: registry)
        defer { reader.shutdown() }
        let idle = try AgentProcess(
            command: StdioChild.idleCommand, arguments: [StdioChild.idleSeconds], registry: registry
        )
        defer { idle.shutdown() }
        let idlePid = try #require(idle.processIdentifier)

        reader.closeStandardInput()

        let bytes = reader.transport.bytes
        let endedAtEndOfFile = await outcome {
            do {
                for try await _ in bytes {}
                return true
            } catch {
                return false
            }
        } ?? false

        #expect(endedAtEndOfFile)
        #expect(reader.processIdentifier == nil)
        #expect(registry.registeredPids == [idlePid])
        #expect(StdioChild.isInProcessTable(pid: idlePid))
    }

    /// Another thread of this process can call `pipe(2)`, and this spawn can
    /// start before that thread sets `FD_CLOEXEC` on the two ends. A pipe that
    /// this test opens and never flags is that window, held open. The agent
    /// must not get a copy of either end.
    @Test func agentHoldsNoDescriptorThatLacksTheCloseOnExecFlag() async throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        defer {
            for descriptor in descriptors {
                close(descriptor)
            }
        }

        for descriptor in descriptors {
            let answer = try await descriptorProbeAnswer(for: descriptor)
            #expect(answer == StdioChild.descriptorClosedAnswer)
        }
    }

    /// The agent writes its diagnostics to the stderr of this process, so the
    /// spawn keeps that descriptor in the agent.
    @Test func agentKeepsTheStandardErrorOfThisProcess() async throws {
        let answer = try await descriptorProbeAnswer(for: STDERR_FILENO)

        #expect(answer == StdioChild.descriptorOpenAnswer)
    }
}

/// Spawns the descriptor probe as an agent and reads its answer until its
/// stdout ends.
///
/// - Parameter descriptor: The descriptor of this process to look for in the
///   agent.
/// - Returns: The whole stdout of the agent, or `nil` when the read failed or
///   did not end in time.
/// - Throws: The errors of
///   ``AgentProcess/init(command:arguments:environment:currentDirectory:registry:)``.
private func descriptorProbeAnswer(for descriptor: Int32) async throws -> String? {
    let probe = try AgentProcess(
        command: StdioChild.descriptorProbeCommand,
        arguments: StdioChild.descriptorProbeArguments(for: descriptor),
        registry: ProcessRegistry()
    )
    defer { probe.shutdown() }

    return await StdioChild.wholeStandardOutput(of: probe)
}
