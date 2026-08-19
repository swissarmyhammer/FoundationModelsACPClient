import Testing

@testable import FoundationModelsACPClient

// M6: `AgentProcess` construction checks. No test in this file spawns a
// process. The tests that spawn a real foreign agent over stdio live in the
// nested `IntegrationTests` package, out of reach of the root `swift test` —
// run them with `swift test --package-path IntegrationTests`.

/// A relative command is refused at construction, before any spawn.
@Test func agentProcessRefusesARelativeCommand() {
    #expect(throws: AgentProcessError.commandNotAbsolute("sh")) {
        _ = try AgentProcess(command: "sh")
    }
}
