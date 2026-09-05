import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPClient

// A child that `posix_spawn` starts inherits every open descriptor of this
// process, unless the descriptor carries `FD_CLOEXEC`. `AgentProcess.spawn`
// closes the four pipe ends of its own spawn inside its own child. A second
// agent, which this process spawns while the first agent is live, must not
// get copies of the pipe ends of the first agent: a copy of the write end of
// the first agent's stdin keeps that stdin open after this process closed its
// own copy, and the first agent then never reads its end of file.
//
// The agents here are `/bin/cat` and `/bin/sleep`, and not an ACP agent. The
// tests that spawn a real foreign agent over stdio live in the nested
// `IntegrationTests` package. The agents register in a private registry, so
// a test that reads `ProcessRegistry.global` beside this one sees no pid of
// this test.

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
}
