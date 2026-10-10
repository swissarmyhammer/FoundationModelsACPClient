import Testing

@testable import FoundationModelsACPClient

// `AgentProcess` construction checks. No test in this file spawns a
// process.

/// A relative command is refused at construction, before any spawn.
@Test func agentProcessRefusesARelativeCommand() {
    #expect(throws: AgentProcessError.commandNotAbsolute("sh")) {
        _ = try AgentProcess(command: "sh")
    }
}
